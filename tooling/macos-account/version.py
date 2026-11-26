"""Resolve the actual release and the single private upgrade fixture, if assigned."""
import json, pathlib, re, sys
root=pathlib.Path(__file__).resolve().parents[2]
pat=r'([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)'
source=re.search(r'^version:\s*('+pat+r')\s*$',(root/'apps/client/pubspec.yaml').read_text(),re.M)
if not source:raise SystemExit('No production version in pubspec')
cfg=json.loads((root/'tooling/macos-account/private-successor.json').read_text(encoding='utf-8-sig'))
destination=re.fullmatch(pat,cfg['successor'])
if not destination:raise SystemExit('Invalid private successor')
test=(cfg['source']==source[1])
if test and (tuple(map(int,destination[1].split('.'))) <= tuple(map(int,source[2].split('.'))) or int(destination[2])<=int(source[3])):raise SystemExit('Private successor must advance version and build')
if sys.argv[1]=='a':print(source[1])
elif sys.argv[1]=='fixture':print(destination[1] if test else '')
elif sys.argv[1]=='b' and test:print(destination[0])
else:raise SystemExit('No private successor assigned to the configured baseline')
