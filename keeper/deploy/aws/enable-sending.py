"""Enable the user-authorized live keeper revision using an authenticated AWS CLI.
Run with AWS_PROFILE set to an authenticated profile. Never contains credentials.
"""
import json,subprocess
from pathlib import Path
BASE=Path(__file__).resolve().parent
REGION='eu-north-1'
def aws(*args):
 p=subprocess.run(['aws',*args,'--region',REGION,'--output','json'],text=True,capture_output=True)
 if p.returncode:raise RuntimeError(p.stderr)
 return json.loads(p.stdout) if p.stdout.strip() else {}
identity=aws('sts','get-caller-identity')
assert identity['Account']=='820140266807','Wrong AWS account'
s=aws('ecs','describe-services','--cluster','multyr-keeper','--services','multyr-keeper-simulation')['services'][0]
assert s['status']=='ACTIVE','Service is not active'
assert s['desiredCount']==1,'Unexpected desired count; review before activation'
old=aws('ecs','describe-task-definition','--task-definition',s['taskDefinition'])['taskDefinition']
v=json.loads((BASE/'task-definition-live.json').read_text())
assert len(old['containerDefinitions'])==1,'Unexpected additional containers'
assert old['containerDefinitions'][0]['image']==v['containerDefinitions'][0]['image'],'Image changed; review latest configuration'
assert old['executionRoleArn']==v['executionRoleArn'] and old['taskRoleArn']==v['taskRoleArn'],'Roles changed'
assert old['containerDefinitions'][0]['command']==['check-loop'],'Service no longer in expected simulation mode'
# Preserve the deployed networking and service configuration; replace only task mode.
r=aws('ecs','register-task-definition','--cli-input-json','file://'+str(BASE/'task-definition-live.json'))['taskDefinition']
aws('ecs','update-service','--cluster','multyr-keeper','--service','multyr-keeper-simulation','--task-definition',r['taskDefinitionArn'],'--deployment-configuration','minimumHealthyPercent=0,maximumPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}')
print('Live-mode revision requested:',r['taskDefinitionArn'],flush=True)
aws('ecs','wait','services-stable','--cluster','multyr-keeper','--services','multyr-keeper-simulation')
s=aws('ecs','describe-services','--cluster','multyr-keeper','--services','multyr-keeper-simulation')['services'][0]
assert s['taskDefinition']==r['taskDefinitionArn'],'Deployment rolled back; inspect ECS events'
assert s['runningCount']==1 and s['pendingCount']==0,'Service not stable'
print('Live service stable. Inspect CloudWatch /ecs/multyr-keeper-primary, prefix live/keeper/.')
