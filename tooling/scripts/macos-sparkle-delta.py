#!/usr/bin/env python3
"""Produce one signed-bundle Sparkle delta from the preceding public Mac release."""
import argparse, contextlib, hashlib, json, os, pathlib, plistlib, re, subprocess, tempfile, urllib.request
from pathlib import Path
REPO='Vilianastclair/WeekGlass'
RELEASE='https://github.com/'+REPO+'/releases/download/'
SPARKLE='https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz'
SPARKLE_SHA='1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27'
LEAF='942A2793EB98F519A4D23E5626C96D2EED0FA03C'
APP_ID='com.viliana.weekglass'
def require(test,message):
    if not test: raise ValueError(message)
def version(s):
    require(isinstance(s,str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)',s),'Invalid release version')
    return tuple(map(int,s.split('.')))
def asset(path):
    h=hashlib.sha256()
    with path.open('rb') as r:
        for chunk in iter(lambda:r.read(1024*1024),b''):h.update(chunk)
    return {'name':path.name,'bytes':path.stat().st_size,'digest':'sha256:'+h.hexdigest()}
def run(*args): return subprocess.run(list(map(str,args)),check=True)
def get(url,path):run('curl','--proto','=https','--proto-redir','=https','--retry','2','--fail','--silent','--show-error','--location','--output',path,url)
def old_release(arch,target):
    raw=subprocess.check_output(['gh','api','--paginate','--slurp',f'repos/{REPO}/releases?per_page=100'])
    releases=[]
    for page in json.loads(raw):
        for r in page:
            tag=r['tag_name']
            if r['draft'] or r['prerelease'] or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',tag) or version(tag[1:])>=version(target):continue
            assets={a['name']:a for a in r['assets']}
            if all(f'WeekGlass-macOS-{a}-{tag[1:]}.dmg' in assets for a in ('arm64','x64')):
                prev=tag[1:];n=f'WeekGlass-macOS-{arch}-{prev}.dmg';m=assets[n]
                require(m['state']=='uploaded' and m['browser_download_url']==RELEASE+tag+'/'+n and re.fullmatch('sha256:[a-f0-9]{64}',m['digest']),'Invalid previous disk image asset')
                releases.append((version(prev),prev,n,m))
    return max(releases,key=lambda r:r[0]) if releases else None
@contextlib.contextmanager
def mounted(dmg,folder):
    folder.mkdir()
    run('hdiutil','attach','-readonly','-nobrowse','-mountpoint',folder,dmg)
    try: yield folder/'WeekGlass.app'
    finally:run('hdiutil','detach',folder)
def inspect(app,arch):
    run('codesign','--verify','--strict','--deep','-R',f'=identifier "{APP_ID}" and certificate leaf = H"{LEAF}"',app)
    p=plistlib.loads((app/'Contents/Info.plist').read_bytes())
    require(p['CFBundleIdentifier']==APP_ID and p['SUFeedURL']==f'https://cloud.viliana.cn/updates/macos/{arch}/appcast.xml','Unexpected bundle or architecture feed')
    require(subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS'/p['CFBundleExecutable'])],text=True).strip()=={'arm64':'arm64','x64':'x86_64'}[arch],'Wrong host architecture')
    return p
def cdhash(app):
    r=subprocess.run(['codesign','-dvvv',str(app)],check=True,stderr=subprocess.PIPE,text=True)
    return re.search(r'^CDHash=([a-f0-9]{40})$',r.stderr,re.M)[1]
def make(arch,new,version_name,build,out,keep_old=None):
    version(version_name);require(arch in ('arm64','x64') and build>0 and new.is_file(),'Invalid target disk image')
    out.mkdir(parents=True,exist_ok=True)
    receipt=out/f'WeekGlass-macOS-{arch}-{version_name}-delta.json'
    row=dict(schema=1,arch=arch,source=None,target={'version':version_name,'build':build,'asset':asset(new)},tool='Sparkle 2.10.1 BinaryDelta',format=4)
    prev=old_release(arch,version_name)
    if not prev:
        row['status']='first-release'
    else:
        _,old_version,name,metadata=prev
        with tempfile.TemporaryDirectory(prefix='weekglass-delta-',dir=os.getenv('RUNNER_TEMP')) as td:
            tmp=Path(td);old=tmp/name;get(metadata['browser_download_url'],old)
            src=asset(old);require((src['digest'],src['bytes'])==(metadata['digest'],metadata['size']),'Previous public disk image failed integrity check')
            archive=tmp/'Sparkle.tar.xz';get(SPARKLE,archive)
            require(asset(archive)['digest']=='sha256:'+SPARKLE_SHA,'Sparkle distribution integrity mismatch')
            tools=tmp/'sparkle';tools.mkdir();run('tar','-xJf',archive,'-C',tools)
            binary=tools/'bin/BinaryDelta'
            with mounted(old,tmp/'source') as a, mounted(new,tmp/'target') as b:
                oldp=inspect(a,arch);newp=inspect(b,arch);prevbuild=int(oldp['CFBundleVersion'])
                require(oldp['CFBundleShortVersionString']==old_version and newp['CFBundleShortVersionString']==version_name and int(newp['CFBundleVersion'])==build and 0<prevbuild<build and oldp['SUPublicEDKey']==newp['SUPublicEDKey'],'Incompatible source and target')
                patch=out/f'WeekGlass-macOS-{arch}-{prevbuild}-to-{build}.delta'
                require(not patch.exists(),'A delta with this name already exists')
                run(binary,'create','--version=4',a,b,patch)
                reconstructed=tmp/'reconstructed'/'WeekGlass.app';reconstructed.parent.mkdir()
                run(binary,'apply',a,reconstructed,patch)
                inspect(reconstructed,arch)
                require(cdhash(reconstructed)==cdhash(b),'Reconstructed app signature differs from the target')
                row.update(source={'version':old_version,'build':prevbuild,'asset':src},delta=asset(patch),target_cdhash=cdhash(b),reconstruction_verified=True)
                row['status']='delta' if patch.stat().st_size<new.stat().st_size else 'full-is-smaller'
                if keep_old:
                    import shutil
                    shutil.copyfile(old,keep_old)
    receipt.write_text(json.dumps(row,indent=2)+'\n')
    print(json.dumps(row))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--arch',choices=('arm64','x64'),required=True);p.add_argument('--new',type=Path,required=True);p.add_argument('--version',required=True);p.add_argument('--build',type=int,required=True);p.add_argument('--out',type=Path,required=True);p.add_argument('--keep-old',type=Path)
    a=p.parse_args();make(a.arch,a.new,a.version,a.build,a.out,a.keep_old)
