"""Public HTTPS CSRF regression check using one disposable synthetic account.

Run sequentially after other public smoke checks have cleared their rate-limit
window. There are no automatic retries. Reports contain only check results,
timestamps and byte counts, never credentials, cookies, grant/code/token values,
account/device identifiers or callback URLs. --ssh enables scoped cleanup even
if registration succeeds but its browser continuation fails.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from copy import copy
from http.cookies import SimpleCookie
import json
from pathlib import Path
import secrets
from urllib.parse import parse_qs, urlsplit

import httpx

from smoke_account_http import begin, browser, cleanup, register, synthetic_record
from smoke_http import auth, authorization_callback, CheckFailed, require, response, stamp


@contextmanager
def at_origin(client, origin):
    """Use both HTTPS ports with the same client and the same CookieJar."""
    previous = client.base_url
    client.base_url = origin
    try:
        yield
    finally:
        client.base_url = previous


class Transfer:
    def __init__(self):
        self.values = {'requests': 0, 'request_body_bytes': 0,
                       'response_wire_bytes': 0, 'response_decoded_bytes': 0}

    def request(self, request):
        self.values['requests'] += 1
        self.values['request_body_bytes'] += len(request.read())

    def response(self, reply):
        reply.read()
        self.values['response_wire_bytes'] += reply.num_bytes_downloaded
        self.values['response_decoded_bytes'] += len(reply.content)


def cookie_names(client):
    return {cookie.name for cookie in client.cookies.jar
            if cookie.name.startswith('wg_authorization')}


def open_page(client, origin):
    before = cookie_names(client)
    with at_origin(client, origin):
        context = begin(client, origin)
    added = cookie_names(client) - before
    require(len(added) == 1, 'one independent cookie per authorization page')
    name = added.pop()
    require(name != 'wg_authorization', 'fixed shared grant cookie replaced')
    cookie = copy(next(item for item in client.cookies.jar if item.name == name))
    require(cookie.path == '/v1/auth/authorize' and not cookie.domain_specified,
            'authorization cookie path and host scope')
    return {'origin': origin, 'context': context, 'cookie': cookie}


def login_form(record, page):
    return {'csrf': page['context'][2], 'username': record['username'],
            'password': record['password']}


def expired_page(reply, record, stage):
    response(reply, 403, stage)
    cache_directives = {item.strip().lower()
                        for item in reply.headers.get('cache-control', '').split(',')}
    require(reply.headers.get('content-type', '').startswith('text/html')
            and reply.headers.get('x-weekglass-error') == 'invalid_csrf',
            stage + ': HTML CSRF rejection')
    require('授权页面已失效' in reply.text and '回到 WeekGlass 点击重新连接' in reply.text,
            stage + ': Chinese reconnect instructions')
    require('<form' not in reply.text and '<input' not in reply.text
            and 'location' not in reply.headers
            and 'no-store' in cache_directives,
            stage + ': no automatic credential resubmission')
    require(record['username'] not in reply.text and record['password'] not in reply.text,
            stage + ': credentials absent from error page')


def complete_page(client, record, page, other_page):
    params, verifier, _ = page['context']
    with at_origin(client, page['origin']):
        reply = browser(client, page['origin'], login_form(record, page))
        target = urlsplit(authorization_callback(reply))
        require(f'{target.scheme}://{target.netloc}{target.path}' == params['redirect_uri'],
                'original page callback unchanged')
        query = parse_qs(target.query)
        require(query.get('state') == [params['state']], 'original page PKCE state unchanged')
        require(reply.headers.get('referrer-policy') == 'no-referrer', 'private callback policy')
        form = {'grant_type': 'authorization_code', 'client_id': 'weekglass-native',
                'code': query['code'][0], 'code_verifier': verifier,
                'redirect_uri': params['redirect_uri'], 'device_id': params['device_id']}
        response(client.post('/v1/auth/token',
                             data=dict(form, code_verifier=other_page['context'][1])),
                 400, 'another page PKCE verifier refused')
        tokens = response(client.post('/v1/auth/token', data=form), 200,
                          'original page PKCE redemption').json()
    require(tokens['account_id'] == record['account_id']
            and tokens['device_id'] == params['device_id'], 'original account and device retained')
    require(page['cookie'].name not in cookie_names(client), 'only consumed cookie removed')


def check_csrf(origin, alternate, ssh, result):
    # Capture synthetic identity before the registration request, so cleanup
    # can still be scoped if a transport/continuation error interrupts it.
    record = synthetic_record()
    transfer = Transfer()
    registration_sent = False
    deleted = False
    checks = result['checks'] = []
    try:
        with httpx.Client(base_url=origin, timeout=40, follow_redirects=False,
                          trust_env=False, event_hooks={'request': [transfer.request],
                                                        'response': [transfer.response]}) as client:
            registration_sent = True
            register(client, origin, record)
            checks.append('one_disposable_account_registered')

            first, second = open_page(client, origin), open_page(client, origin)
            require(cookie_names(client) == {first['cookie'].name, second['cookie'].name},
                    'two pages coexist in one cookie jar')
            invalid = browser(client, origin,
                              dict(login_form(record, first), csrf=secrets.token_urlsafe(32)))
            expired_page(invalid, record, 'incorrect CSRF rejected')
            checks.append('incorrect_login_csrf_refused')
            complete_page(client, record, first, second)
            require(cookie_names(client) == {second['cookie'].name},
                    'older page completion preserves newer page')
            checks.append('older_page_completes_first_without_erasing_newer')

            # Restore the consumed synthetic cookie to prove the DB grant is
            # single-use, rather than testing only the missing-cookie case.
            client.cookies.jar.set_cookie(copy(first['cookie']))
            expired_page(browser(client, origin, {'action': 'continue',
                         'csrf': first['context'][2]}), record, 'consumed grant rejected')
            client.cookies.delete(first['cookie'].name, domain=first['cookie'].domain,
                                  path=first['cookie'].path)
            checks.append('consumed_grant_returns_chinese_403_without_credentials')
            complete_page(client, record, second, first)
            require(not cookie_names(client), 'first pair cookies consumed independently')
            checks.append('newer_page_still_redeems_original_state_and_device')
            checks.append('same_origin_handoff_with_hashed_script_and_manual_callback')

            first, second = open_page(client, origin), open_page(client, alternate)
            with at_origin(client, alternate):
                crossed = response(browser(client, origin, login_form(record, first)),
                                   403, 'cross-port foreign Origin refused')
                require(crossed.json().get('code') == 'invalid_origin',
                        'cross-port Origin remains strict')
                forged = browser(client, alternate, {'action': 'continue', 'csrf': first['context'][2]})
                expired_page(forged, record, 'same target Origin cannot use other port grant')
                sent = SimpleCookie()
                sent.load(forged.request.headers.get('cookie', ''))
                require({first['cookie'].name, second['cookie'].name}.issubset(set(sent)),
                        'both ports actually share the cookie jar')
            checks += ['same_host_ports_share_cookies', 'cross_port_origin_refused',
                       'grant_selector_bound_to_issuing_origin']
            complete_page(client, record, second, first)
            require(cookie_names(client) == {first['cookie'].name},
                    'newer alternate-port page preserves older primary-port page')
            complete_page(client, record, first, second)
            require(not cookie_names(client), 'second pair cookies consumed independently')
            checks += ['newer_page_completes_first_without_erasing_older',
                       'both_ports_redeem_original_state_device_and_pkce',
                       'other_page_pkce_verifiers_refused']

            response(client.request('DELETE', '/v1/me/account',
                     json={'current_password': record['password'], 'confirmation': record['username']},
                     headers=auth(record['tokens'])), 204, 'delete disposable CSRF account')
            response(client.get('/v1/me/account', headers=auth(record['tokens'])),
                     401, 'deleted synthetic account inaccessible')
            deleted = True
            checks.append('synthetic_account_deleted_and_access_revoked')
    finally:
        try:
            if registration_sent:
                cleanup(ssh, record)
                deleted = True
        finally:
            result.update(passed=len(checks), synthetic_account_deleted=deleted,
                          transfer=transfer.values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin', default='https://cloud.viliana.cn')
    parser.add_argument('--alternate', default='https://cloud.viliana.cn:8443')
    parser.add_argument('--ssh', required=True, help='authorized host alias for synthetic-only cleanup')
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = {'started_at': stamp()}
    try:
        primary, alternate = urlsplit(args.origin), urlsplit(args.alternate)
        require(primary.scheme == alternate.scheme == 'https'
                and primary.hostname == alternate.hostname
                and (primary.port or 443) != (alternate.port or 443)
                and not any((primary.path, primary.query, primary.fragment, primary.username,
                             alternate.path, alternate.query, alternate.fragment, alternate.username)),
                'two HTTPS origins on the same host and different ports required')
        check_csrf(args.origin, args.alternate, args.ssh, result)
        result['success'] = True
    except CheckFailed as error:
        result.update(success=False, error=str(error))
    except Exception as error:
        # Exception text may include request URLs. Keep only its class name.
        result.update(success=False, error_type=type(error).__name__)
    result['finished_at'] = stamp()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['success'] else 1)


if __name__ == '__main__':
    main()
