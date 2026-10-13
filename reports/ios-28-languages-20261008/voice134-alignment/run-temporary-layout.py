#!/usr/bin/python3
"""Serial, isolated UI layout proof; only deletes the simulator created here."""
import datetime,json,pathlib,plistlib,subprocess,sys
root=pathlib.Path.cwd();report=root/'reports/ios-28-languages-20261008/voice134-alignment'
kind=sys.argv[1]; assert kind in ('narrow','ipad')
device_type='iPhone-SE-3rd-generation' if kind=='narrow' else 'iPad-mini-A17-Pro'
suffix=sys.argv[2] if len(sys.argv)>2 else ''
folder=report/('layout-final-'+kind+suffix);folder.mkdir(exist_ok=False)
def run(*a,**kw):return subprocess.run(a,check=True,**kw)
sim=subprocess.check_output(['xcrun','simctl','create','CastReader Voice Layout '+kind+' 20261009','com.apple.CoreSimulator.SimDeviceType.'+device_type,'com.apple.CoreSimulator.SimRuntime.iOS-26-5'],text=True).strip()
meta={'simulator':sim,'deviceType':device_type,'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'contentSize':'accessibility-extra-extra-extra-large','realAccountRequired':False,'status':'starting'}
(folder/'device.json').write_text(json.dumps(meta,indent=2)+'\n')
try:
 run('xcrun','simctl','boot',sim)
 run('xcrun','simctl','bootstatus',sim,'-b')
 run('xcrun','simctl','ui',sim,'content_size',meta['contentSize'])
 base=pathlib.Path('/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReaderIOS28Acceptance/Build/Products')
 source=max(base.glob('CastReader_CastReader_*.xctestrun'),key=lambda p:p.stat().st_mtime)
 if kind=='ipad':
  checks=['testVoicePanelRetainsActualReadViewportThroughDismissal','testVoicePanelRetainsActualExplainViewportThroughDismissal','testVoicePanelAllowsStablePageObservationWithoutChangingViewport']
  with (folder/'viewport-unit.log').open('w') as log:
   result=subprocess.run(['xcodebuild','-xctestrun',str(source),'-destination','platform=iOS Simulator,id='+sim,'-parallel-testing-enabled','NO','-collect-test-diagnostics','never',*[ '-only-testing:CastReaderTests/KindleReadingSettingsOwnershipTests/'+x for x in checks],'-resultBundlePath',str(folder/'viewport-unit.xcresult'),'test-without-building'],stdout=log,stderr=subprocess.STDOUT)
  meta['viewportUnitExit']=result.returncode
  with (folder/'viewport-unit-summary.json').open('w') as out:subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(folder/'viewport-unit.xcresult'),'--format','json'],stdout=out)
 data=plistlib.loads(source.read_bytes())
 for config in data['TestConfigurations']:
  config['TestTargets']=[t for t in config['TestTargets'] if t['BlueprintName']=='CastReaderUITests']
  for t in config['TestTargets']:t.setdefault('EnvironmentVariables',{})['CASTREADER_VOICE_ALIGNMENT_REPORT']=str(folder/'screenshots')
 test_run=base/('VoiceLayoutFinal-'+kind+'.xctestrun');test_run.write_bytes(plistlib.dumps(data))
 with (folder/'test.log').open('w') as log:
  result=subprocess.run(['xcodebuild','-xctestrun',str(test_run),'-destination','platform=iOS Simulator,id='+sim,'-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-only-testing:CastReaderUITests/VoiceAlignmentLiveUITests/testLargeTypeVoiceControlsRemainReachable','-resultBundlePath',str(folder/'tests.xcresult'),'test-without-building'],stdout=log,stderr=subprocess.STDOUT)
 meta['testExit']=result.returncode;meta['status']='passed_pending_visual_review' if result.returncode==0 else 'failed_needs_review'
 with (folder/'summary.json').open('w') as out:subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path',str(folder/'tests.xcresult'),'--format','json'],stdout=out)
finally:
 subprocess.run(['xcrun','simctl','shutdown',sim],capture_output=True)
 result=subprocess.run(['xcrun','simctl','delete',sim],capture_output=True)
 meta['ownTemporaryDeviceDeleted']=result.returncode==0;meta['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat()
 (folder/'device.json').write_text(json.dumps(meta,indent=2)+'\n')
 print(json.dumps(meta),flush=True)
