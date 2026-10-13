import pathlib,plistlib,subprocess,json,hashlib,importlib.util
root=pathlib.Path.cwd(); report=root/'reports/ios-release-1.2.49'
archive=pathlib.Path('/Users/xuxuheng/Library/Developer/Xcode/Archives/2026-10-11/CastReader-1.2.49-77.xcarchive')
app=archive/'Products/Applications/CastReader.app'
manifest=json.loads((report/'candidate-source-manifest.json').read_text())
assert all(hashlib.sha256((root/p).read_bytes()).hexdigest()==h for p,h in manifest['files'].items()),'Application source changed'
assert subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()=='0be026c0ed6cb8e97f12d6b0aa13857941ecfd70'
assert not subprocess.check_output(['git','diff','--name-only'],text=True).strip()
products=[]
for bundle in [app]+sorted(app.glob('PlugIns/*.appex')):
 info=plistlib.loads((bundle/'Info.plist').read_bytes())
 assert info['CFBundleShortVersionString']=='1.2.49' and info['CFBundleVersion']=='77'
 assert info['UIDeviceFamily']==[1,2]
 subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True,capture_output=True)
 signing=subprocess.run(['codesign','-dvv',str(bundle)],check=True,capture_output=True,text=True).stderr
 assert 'TeamIdentifier=KQW6UNZE8J' in signing
 ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL))
 assert ent['com.apple.developer.team-identifier']=='KQW6UNZE8J'
 binary=bundle/info['CFBundleExecutable'];payload=binary.read_bytes()
 markers=['-CastReaderCaptureTextB64','-CastReaderMultilingualAcceptance','readerLanguagePlaybackMetrics','-CastReaderCloneCreditsPreview','-CastReaderDisableDebugPro','-CastReaderForcePro']
 assert not [m for m in markers if m.encode() in payload],f'Debug marker in {bundle.name}'
 products.append({'bundle':bundle.name,'identifier':info['CFBundleIdentifier'],'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'families':info['UIDeviceFamily'],'team':'KQW6UNZE8J','binarySHA256':hashlib.sha256(payload).hexdigest(),'getTaskAllow':ent.get('get-task-allow'),'architectures':subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()})
assert len(products)==4
info=plistlib.loads((app/'Info.plist').read_bytes());assert info.get('ITSAppUsesNonExemptEncryption')==False
assert info.get('CastReaderInternalDistributionControlsEnabled') in (False,'NO')
locales=sorted(p.stem for p in app.glob('*.lproj'))
expected=list(json.loads((root/'store/app-store/1.2.48/metadata.json').read_text()))
assert len(expected)==28
assert set(expected).issubset(locales),(set(expected)-set(locales))
compiled_strings={loc: len(plistlib.loads((app/(loc+'.lproj')/'Localizable.strings').read_bytes())) for loc in expected}
assert all(n>=1500 for n in compiled_strings.values()),compiled_strings
spec=importlib.util.spec_from_file_location('fixture_audit',root/'scripts/verify_release_no_shelf_fixtures.py');f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
files,hits=f.inspect(app);assert not hits,hits
mainpayload=(app/info['CFBundleExecutable']).read_bytes()
for endpoint in ['https://api.castreader.ai','https://api.castreader.cn','https://quickread.castreader.cn']:
 assert endpoint.encode() in mainpayload,endpoint
hashes={str(p.relative_to(archive)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(archive.rglob('*')) if p.is_file()}
archive_digest=hashlib.sha256(''.join(k+'\0'+v+'\n' for k,v in sorted(hashes.items())).encode()).hexdigest()
output={'status':'PASS','archive':str(archive),'sourceCommit':'0be026c0ed6cb8e97f12d6b0aa13857941ecfd70','applicationManifestSHA256':manifest.get('sha256',manifest.get('aggregateSHA256')),'archiveManifestSHA256':archive_digest,'products':products,'locales':locales,'compiledMainStringCounts':compiled_strings,'fixtureFilesScanned':len(files),'fixtureHits':hits,'productionEndpointsVerified':True,'nonExemptEncryption':False,'signingNote':'Archive development signatures verified; official export re-signs its export copy for App Store distribution without mutating the archived product.'}
(report/'archive-file-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
(report/'archive-verification.json').write_text(json.dumps(output,indent=2)+'\n')
core=json.loads((report/'core-gate.json').read_text());core['archiveSourceVerified']=True;core['archiveCommit']=output['sourceCommit'];core['archiveManifestSHA256']=archive_digest;(report/'core-gate.json').write_text(json.dumps(core,indent=2)+'\n')
print(json.dumps(output,indent=2))
