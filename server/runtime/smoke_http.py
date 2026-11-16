"""Black-box deployed-service smoke test; only a fresh synthetic account is allowed.

All account access uses actual HTTP PKCE login and bearer tokens. Credentials are
read from local files and never included in reports. Does not touch real diaries.
"""
from __future__ import annotations
import argparse
import base64
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import secrets
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


class CheckFailed(Exception):
    pass


def require(condition, stage):
    if not condition:
        raise CheckFailed(stage)


def response(reply, status, stage):
    require(reply.status_code == status, stage + ': HTTP ' + str(reply.status_code) + ', expected ' + str(status))
    return reply


def authorization_callback(reply, *, signup=False):
    """Check the HTTP handoff contract; real browser execution is separate QA."""
    response(reply, 200, 'same-origin authorization handoff')
    require('location' not in reply.headers and reply.headers.get('content-type', '').startswith('text/html'),
            'successful form returns a document instead of a cross-origin 302')
    require(reply.headers.get('referrer-policy') == 'no-referrer'
            and 'no-store' in reply.headers.get('cache-control', ''), 'handoff privacy policy')
    csp = reply.headers.get('content-security-policy', '')
    require("form-action 'self';" in csp and '127.0.0.1' not in csp, 'credential form policy remains same-origin')
    scripts = re.findall(r'<script>(.*?)</script>', reply.text, re.S)
    require(len(scripts) == 1, 'one fixed handoff script')
    digest = base64.b64encode(hashlib.sha256(scripts[0].encode()).digest()).decode()
    require("script-src 'sha256-" + digest + "';" in csp, 'handoff script matches exact CSP hash')
    class Parser(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.links = []
        def handle_starttag(self, tag, attrs):
            values = dict(attrs)
            if tag == 'a' and values.get('id') == 'handoff-link':
                self.links.append(values)
    parser = Parser()
    parser.feed(reply.text)
    require(len(parser.links) == 1 and parser.links[0].get('rel') == 'noreferrer', 'manual private handoff link')
    target = urlsplit(parser.links[0].get('href', ''))
    require(target.scheme == 'http' and target.hostname == '127.0.0.1'
            and target.port is not None and 1024 <= target.port <= 65535
            and not target.username and not target.password and not target.fragment
            and target.path == '/oauth/callback', 'exact loopback-only handoff')
    query = parse_qs(target.query)
    expected = {'code', 'state', 'signup'} if signup else {'code', 'state'}
    require(set(query) == expected and all(len(value) == 1 for value in query.values())
            and (not signup or query['signup'] == ['1']), 'only expected fields in callback URL')
    require(re.fullmatch(r'[A-Za-z0-9_-]{43}', query['code'][0]) is not None, 'bounded authorization code')
    require('账号验证通过' in reply.text and '以应用中的连接结果为准' in reply.text
            and '<noscript>' in reply.text and '<form' not in reply.text, 'explicit handoff and fallback feedback')
    return parser.links[0]['href']


def stamp():
    return datetime.now(timezone.utc).isoformat().replace('+00:00','Z')


def parse_time(value):
    result=datetime.fromisoformat(value.replace('Z','+00:00'))
    require(result.tzinfo is not None,'signed metadata requires timezone')
    return result


def signed(data, key, kind, floor):
    outer=json.loads(data)
    raw_key=key.public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
    require(outer['format']==1 and outer['key_id']==hashlib.sha256(raw_key).hexdigest(),'pinned update identity')
    raw=base64.b64decode(outer['signed'],validate=True)
    key.verify(base64.b64decode(outer['signature'],validate=True),raw)
    payload=json.loads(raw)
    require(payload['schema']==1 and payload['product']=='weekglass' and payload['platform']=='windows-x64' and payload['channel']=='stable','update release identity')
    require(type(payload['build']) is int and payload['build']>=floor,'update rollback floor')
    now=datetime.now(timezone.utc)
    limit=7 if kind=='channel' else 31
    require(parse_time(payload['generated_at'])<=now+timedelta(minutes=5),'future update metadata')
    require(now<parse_time(payload['expires_at'])<=parse_time(payload['generated_at'])+timedelta(days=limit),'update metadata validity')
    if kind=='channel': require(payload.get('kind')=='weekglass-channel','channel type')
    return payload


def check_updates(client, public_file, expected_build):
    key=serialization.load_pem_public_key(public_file.read_bytes())
    require(isinstance(key,Ed25519PublicKey),'Ed25519 public key')
    channel=response(client.get('/updates/v1/channels/windows-x64/stable.json'),200,'signed update channel')
    require(len(channel.content)<=16384,'bounded channel metadata')
    head=signed(channel.content,key,'channel',expected_build)
    descriptor=head['manifest']
    expected_path=f'manifests/windows-x64/stable/{head["build"]}/{descriptor["sha256"]}.json'
    require(descriptor['path']==expected_path and re.fullmatch('[a-f0-9]{64}',descriptor['sha256']),'same-origin manifest path')
    require(descriptor['size']<=4*1024*1024,'bounded manifest')
    manifest=response(client.get('/updates/v1/'+descriptor['path']),200,'immutable manifest')
    require(len(manifest.content)==descriptor['size'] and hashlib.sha256(manifest.content).hexdigest()==descriptor['sha256'],'manifest hash binding')
    release=signed(manifest.content,key,'manifest',expected_build)
    require(release['build']==head['build'] and release['version']==head['version'],'channel matches manifest')
    candidates=[x for entry in release['files'] for x in [entry['full'],*entry['patches']] if x['size']>=64]
    require(bool(candidates),'object suitable for range test')
    item=min(candidates,key=lambda x:x['size'])
    require(re.fullmatch('[a-f0-9]{64}',item['sha256']) and item['size']<=256*1024*1024,'bounded object descriptor')
    path=f'/updates/v1/objects/{item["sha256"][:2]}/{item["sha256"]}'
    obj=response(client.get(path),200,'update object GET')
    require(obj.headers.get('content-encoding','identity')=='identity','stored update bytes must not be reencoded')
    require(len(obj.content)==item['size'] and hashlib.sha256(obj.content).hexdigest()==item['sha256'],'update object hash')
    header=response(client.head(path),200,'update object HEAD')
    require(header.content==b'' and int(header.headers['content-length'])==item['size'],'HEAD length')
    require(header.headers.get('accept-ranges')=='bytes','range advertisement')
    etag=header.headers.get('etag')
    require(etag and not etag.startswith('W/'),'strong object ETag')
    response(client.get(path,headers={'If-None-Match':etag}),304,'conditional object request')
    ranged=response(client.get(path,headers={'Range':'bytes=0-63','If-Range':etag}),206,'resumable range')
    require(ranged.content==obj.content[:64] and ranged.headers.get('content-range')==f'bytes 0-63/{item["size"]}','range byte and extent match')
    return {'build':head['build'],'channel_expires_at':head['expires_at'],
            'signature_verified':True,'manifest_hash_verified':True,'object_hash_verified':True,
            'head':True,'etag_304':True,'range_206':True,'range_test_object_bytes':item['size']}


def login(client, username, password, origin):
    verifier=secrets.token_urlsafe(48)
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
    device=str(uuid4())
    params={'response_type':'code','client_id':'weekglass-native','redirect_uri':'http://127.0.0.1:54321/oauth/callback',
            'code_challenge':challenge,'code_challenge_method':'S256','state':secrets.token_urlsafe(32),'device_id':device}
    page=response(client.get('/v1/auth/authorize',params=params),200,'PKCE authorize')
    require('no-store' in page.headers.get('cache-control','') and 'HttpOnly' in page.headers.get('set-cookie',''),'login cookie and cache policy')
    match=re.search(r'name="csrf" value="([^"]+)"',page.text)
    require(match is not None,'CSRF form')
    answer=client.post('/v1/auth/authorize',data={'csrf':match.group(1),'username':username,'password':password},headers={'Origin':origin})
    location=urlsplit(authorization_callback(answer))
    require(f'{location.scheme}://{location.netloc}{location.path}'==params['redirect_uri'],'exact callback')
    query=parse_qs(location.query)
    require(query['state']==[params['state']],'authorization state binding')
    result=response(client.post('/v1/auth/token',data={'grant_type':'authorization_code','client_id':'weekglass-native',
            'redirect_uri':params['redirect_uri'],'device_id':device,'code':query['code'][0],'code_verifier':verifier}),200,'PKCE token redemption')
    require('no-store' in result.headers.get('cache-control',''),'token cache policy')
    return result.json()


def auth(tokens):
    return {'Authorization':'Bearer '+tokens['access_token']}


def event(eid):
    instant=datetime.now(timezone.utc).replace(microsecond=0)
    return {'id':eid,'title':'WeekGlass 云同步验证','notes':'合成测试数据，不含用户日程。','color_key':'mist_blue',
            'is_all_day':False,'start_utc':instant.isoformat().replace('+00:00','Z'),
            'end_utc':(instant+timedelta(minutes=15)).isoformat().replace('+00:00','Z'),
            'all_day_start':None,'all_day_end_exclusive':None,'time_zone_id':'Asia/Shanghai',
            'recurrence_rule':None,'series_id':None,'import_source':None,'import_fingerprint':None,
            'created_at_utc':instant.isoformat().replace('+00:00','Z'),
            'updated_at_utc':instant.isoformat().replace('+00:00','Z'),'version':1,'deleted_at_utc':None}


def batch(tokens, entries):
    return {'batch_id':str(uuid4()),'device_id':tokens['device_id'],'dataset_id':tokens['dataset_id'],
            'sync_epoch':tokens['sync_epoch'],'mutations':[{'mutation_id':str(uuid4()),'event_id':eid,
                'base_revision':revision,'operation':'delete' if value is None else 'put','event':value}
                for eid,revision,value in entries]}


def check_sync(base_url, username, password, origin):
    checks=[]
    with httpx.Client(base_url=base_url,timeout=40,follow_redirects=False,trust_env=False) as a, \
         httpx.Client(base_url=base_url,timeout=40,follow_redirects=False,trust_env=False) as b:
        response(a.get('/v1/devices'),401,'unauthenticated account read')
        first,second=login(a,username,password,origin),login(b,username,password,origin)
        require(first['account_id']==second['account_id'] and first['device_id']!=second['device_id'],'two distinct devices same account')
        checks.append('two_device_PKCE_login')
        entitlement=response(a.get('/v1/me/entitlements',headers=auth(first)),200,'entitlements').json()
        require(entitlement['sync_write'] is True,'test account needs an explicit trial grant')
        baseline=response(a.post('/v1/sync/snapshots',headers=auth(first)),200,'initial snapshot').json()
        require(baseline['records']==[] and baseline['next_page_token'] is None,'fresh empty synthetic account required')
        eid1,eid2,conflict_only=['smoke-'+uuid4().hex for _ in range(3)]
        one,two=event(eid1),event(eid2)
        two['title']=''
        create=batch(second,[(eid1,None,one),(eid2,None,two)])
        saved=response(b.post('/v1/sync/batches',json=create,headers=auth(second)),200,'atomic create').json()
        require(len(saved['results'])==2,'both events committed')
        replay=response(b.post('/v1/sync/batches',json=create,headers=auth(second)),200,'idempotent retry').json()
        require(replay==saved,'identical persisted receipt')
        require(response(a.get('/v1/sync/batches/'+create['batch_id'],headers=auth(first)),200,'receipt lookup').json()==saved,'cross-device receipt lookup')
        pulled=response(a.get('/v1/sync/changes',params={'cursor':baseline['boundary_cursor']},headers=auth(first)),200,'other-device pull').json()
        require(len(pulled['changes'])==1 and {x['id'] for x in pulled['changes'][0]['records']}=={eid1,eid2},'complete atomic change batch')
        response(a.post('/v1/sync/ack',json={'device_id':first['device_id'],'cursor':pulled['next_cursor']},headers=auth(first)),204,'applied cursor ack')
        checks.extend(['atomic_batch','idempotent_receipt','cross_device_delta','cursor_ack','empty_title'])
        revision=saved['results'][0]['revision']
        modified=deepcopy(one);modified.update(title='已由第二台设备修改',version=2)
        update=batch(second,[(eid1,revision,modified)])
        updated=response(b.post('/v1/sync/batches',json=update,headers=auth(second)),200,'update from second device').json()
        stale=batch(first,[(eid1,revision,one),(conflict_only,None,event(conflict_only))])
        conflict=response(a.post('/v1/sync/batches',json=stale,headers=auth(first)),409,'stale atomic batch conflict').json()
        require(conflict['code']=='revision_conflict' and conflict['conflicts'][0]['current']['event']['title']==modified['title'],'conflict keeps remote content')
        response(a.get('/v1/sync/batches/'+stale['batch_id'],headers=auth(first)),404,'conflicted batch not committed')
        delta=response(a.get('/v1/sync/changes',params={'cursor':pulled['next_cursor']},headers=auth(first)),200,'pull accepted edit').json()
        require(delta['changes'][0]['records'][0]['event']['title']==modified['title'],'accepted edit preserved')
        checks.append('conflict_all_or_nothing')
        deletion=batch(first,[(eid1,updated['results'][0]['revision'],None)])
        response(a.post('/v1/sync/batches',json=deletion,headers=auth(first)),200,'delete current revision')
        deleted=response(b.get('/v1/sync/changes',params={'cursor':delta['next_cursor']},headers=auth(second)),200,'pull tombstone').json()
        record=deleted['changes'][0]['records'][0]
        require(record['id']==eid1 and record['event'] is None and record['deleted_at_utc'] is not None,'deletion propagates as tombstone')
        exported=response(a.get('/v1/exports/calendar',headers=auth(first)),200,'account export').json()
        require({x['id'] for x in exported['records']}=={eid1,eid2},'failed batch creates no phantom event')
        require(any(x['id']==eid2 and x['event']['title']=='' for x in exported['records']),'export keeps live data')
        checks.extend(['tombstone','export'])
        refreshed=response(b.post('/v1/auth/token',data={'grant_type':'refresh_token','client_id':'weekglass-native',
                'device_id':second['device_id'],'refresh_token':second['refresh_token']}),200,'refresh rotation').json()
        require(refreshed['refresh_token']!=second['refresh_token'],'rotating refresh token')
        response(a.delete('/v1/devices/'+second['device_id'],headers=auth(first)),204,'device revoke')
        response(b.get('/v1/devices',headers=auth(refreshed)),401,'revoked access refused')
        response(b.post('/v1/auth/token',data={'grant_type':'refresh_token','client_id':'weekglass-native',
                'device_id':second['device_id'],'refresh_token':refreshed['refresh_token']}),400,'revoked refresh refused')
        checks.extend(['refresh_rotation','device_revocation'])
        cleanup=batch(first,[(eid2,revision,None)])
        response(a.post('/v1/sync/batches',json=cleanup,headers=auth(first)),200,'synthetic event cleanup')
        response(a.post('/v1/auth/revoke',json={'device_id':first['device_id'],'refresh_token':first['refresh_token']}),204,'logout')
        response(a.get('/v1/devices',headers=auth(first)),401,'logout access refused')
        checks.append('logout')
    return {'checks':checks,'passed':len(checks),'synthetic_events_soft_deleted':2}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url',required=True)
    parser.add_argument('--username-file',type=Path,required=True)
    parser.add_argument('--password-file',type=Path,required=True)
    parser.add_argument('--public-key',type=Path,default=Path(__file__).resolve().parents[1]/'update_tools/keys/release-ed25519.pub.pem')
    parser.add_argument('--expected-build',type=int,default=16)
    parser.add_argument('--report',type=Path)
    args=parser.parse_args()
    result={'started_at':stamp(),'transport':'HTTP black-box; no application dependency overrides'}
    try:
        username=args.username_file.read_text(encoding='utf-8').strip()
        password=args.password_file.read_text(encoding='utf-8').strip()
        require(re.fullmatch(r'(smoke|test|qa)-[a-zA-Z0-9_.-]+',username),'only a fresh synthetic smoke-/test-/qa- account may be used')
        with httpx.Client(base_url=args.base_url,timeout=40,follow_redirects=False,trust_env=False) as client:
            require(response(client.get('/healthz'),200,'health').json()['status']=='ok','health ready')
            info=response(client.get('/v1/server-info'),200,'server discovery').json()
            origin_parts=urlsplit(info['authorization_endpoint'])
            origin=f'{origin_parts.scheme}://{origin_parts.netloc}'
            result['updates']=check_updates(client,args.public_key,args.expected_build)
        result['sync']=check_sync(args.base_url,username,password,origin)
        result['success']=True
    except CheckFailed as error:
        result.update(success=False,error=str(error))
    except Exception as error:
        # Never print request/response repr, OAuth URLs, passwords, codes or tokens.
        result.update(success=False,error_type=type(error).__name__)
    result['finished_at']=stamp()
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2))
    raise SystemExit(0 if result['success'] else 1)


if __name__=='__main__': main()
