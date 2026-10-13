import sys,os,json,hashlib,subprocess
from pathlib import Path
sys.path.insert(0,'/tmp/castreader-pro-backup-sdk')
from qcloud_cos import CosConfig,CosS3Client
root=Path(__file__).parent;os.umask(0o077)
remote=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo cat /etc/castreader/voice-clone.env'],capture_output=True,check=True,text=True)
e={}
for line in remote.stdout.splitlines():
 if '=' in line and not line.startswith('#'):
  k,v=line.split('=',1);e[k]=v.strip().strip('"').strip("'")
bucket=e['TENCENT_COS_BUCKET'];region=e['TENCENT_COS_REGION'];assert bucket=='castreader-voice-1323065328' and region=='ap-shanghai'
client=CosS3Client(CosConfig(Region=region,SecretId=e['TENCENT_COS_SECRET_ID'],SecretKey=e['TENCENT_COS_SECRET_KEY'],Scheme='https'))
acl=client.get_bucket_acl(Bucket=bucket)
raw=json.dumps(acl).lower();assert 'allusers' not in raw and 'authenticatedusers' not in raw
p=root/'cn-pre-release-private.tar.gz';sha=hashlib.sha256(p.read_bytes()).hexdigest();key='runtime-releases/quickread-cn/pro-consistency-20260924/before-'+sha[:16]+'.tar.gz'
try:client.head_object(Bucket=bucket,Key=key);exists=True
except Exception as ex:
 if getattr(ex,'get_status_code',lambda:None)()!=404:raise
 exists=False
if not exists:
 with p.open('rb') as f:client.put_object(Bucket=bucket,Key=key,Body=f,ACL='private')
body=client.get_object(Bucket=bucket,Key=key)['Body'].get_raw_stream();h=hashlib.sha256();n=0
while True:
 chunk=body.read(1024*1024)
 if not chunk:break
 h.update(chunk);n+=len(chunk)
assert h.hexdigest()==sha and n==p.stat().st_size
receipt={'region':region,'bucket':bucket,'public':False,'key':key,'bytes':n,'sha256':sha,'readback_sha256':h.hexdigest(),'verified':True}
raw=json.dumps(receipt,indent=2).encode();rkey=key+'.receipt.json';client.put_object(Bucket=bucket,Key=rkey,Body=raw,ACL='private');assert client.get_object(Bucket=bucket,Key=rkey)['Body'].get_raw_stream().read()==raw
(root/'cn-backup-receipt.json').write_bytes(raw);print(json.dumps(receipt))
