"""Post-Safe rollout only. Requires a newly built keeper image pinned by digest.
Credentials are never printed. ECS input uses a private temporary file, removed immediately after the AWS CLI call.
"""
import argparse, json, re, subprocess, tempfile, os
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--image',required=True);a=p.parse_args()
assert re.fullmatch(r'820140266807\.dkr\.ecr\.eu-north-1\.amazonaws\.com/multyr-keeper@sha256:[0-9a-f]{64}',a.image),'Expected keeper ECR image digest'
root=Path(__file__).resolve().parents[2]
subprocess.run(['node','scripts/check-ema-migration.mjs'],cwd=root,check=True)
def aws(*args, payload=None):
    command=['aws',*args,'--region','eu-north-1','--output','json']
    temporary=None
    try:
        if payload is not None:
            with tempfile.NamedTemporaryFile(mode='w',prefix='multyr-ecs-',suffix='.json',delete=False) as f:
                temporary=f.name
                json.dump(payload,f)
            command+=['--cli-input-json','file://'+temporary]
        r=subprocess.run(command,capture_output=True,text=True)
    finally:
        if temporary:os.unlink(temporary)
    if r.returncode:
        message=r.stderr
        if payload:
            for container in payload.get('containerDefinitions',[]):
                for item in container.get('environment',[]):
                    if item.get('value'):message=message.replace(item['value'],'<redacted>')
        message=re.sub(r'https?://\S+','<url>',message)
        raise RuntimeError('AWS operation failed: '+args[0]+' '+args[1]+': '+message[:1500])
    return json.loads(r.stdout) if r.stdout.strip() else {}
assert aws('sts','get-caller-identity')['Account']=='820140266807'
s=aws('ecs','describe-services','--cluster','multyr-keeper','--services','multyr-keeper-simulation')['services'][0]
assert s['status']=='ACTIVE' and s['desiredCount']==1
old=aws('ecs','describe-task-definition','--task-definition',s['taskDefinition'])['taskDefinition']
allowed=['family','taskRoleArn','executionRoleArn','networkMode','containerDefinitions','volumes','placementConstraints','requiresCompatibilities','cpu','memory','pidMode','ipcMode','proxyConfiguration','inferenceAccelerators','ephemeralStorage','runtimePlatform']
new={k:old[k] for k in allowed if k in old}
assert len(new['containerDefinitions'])==1
c=new['containerDefinitions'][0]
assert c.get('command')==['run'],'Unexpected keeper execution mode'
c['image']=a.image
env=c.setdefault('environment',[])
env[:]=[x for x in env if x['name']!='KEEPER_CONFIG']
env.append({'name':'KEEPER_CONFIG','value':'/app/config/arbitrum-one.ema-first-20261023.json'})
r=aws('ecs','register-task-definition',payload=new)['taskDefinition']
aws('ecs','update-service','--cluster','multyr-keeper','--service','multyr-keeper-simulation','--task-definition',r['taskDefinitionArn'],'--deployment-configuration','minimumHealthyPercent=0,maximumPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}')
print(json.dumps({'status':'rollout-requested','previousTaskDefinition':s['taskDefinition'],'newTaskDefinition':r['taskDefinitionArn'],'image':a.image}))
print('Confirm ECS stabilization and first W2/W5 receipts before marking rollout complete.')
