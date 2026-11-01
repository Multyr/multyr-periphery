"""Rotate the existing ECS keeper RPC, preserving its image, mode and other settings.
Uses normal AWS CLI credentials. Reads RPC_URLS from the ignored keeper/.env.
"""
import json, subprocess, tempfile, os
from pathlib import Path
BASE = Path(__file__).resolve().parents[2]
rpc = next(line.split('=', 1)[1].strip().strip('\"\'') for line in (BASE / '.env').read_text().splitlines() if line.startswith('RPC_URLS='))
def aws(*args):
    p = subprocess.run(['aws', *args, '--region', 'eu-north-1', '--output', 'json'], text=True, capture_output=True)
    if p.returncode:
        raise RuntimeError(p.stderr.replace(rpc, '[RPC REDACTED]'))
    return json.loads(p.stdout) if p.stdout.strip() else {}
assert aws('sts', 'get-caller-identity')['Account'] == '820140266807', 'Wrong AWS account'
service = aws('ecs', 'describe-services', '--cluster', 'multyr-keeper', '--services', 'multyr-keeper-simulation')['services'][0]
task = aws('ecs', 'describe-task-definition', '--task-definition', service['taskDefinition'])['taskDefinition']
container = next(c for c in task['containerDefinitions'] if c['name'] == 'keeper')
assert not any(s['name'] == 'RPC_URLS' for s in container.get('secrets', [])), 'RPC_URLS now uses Secrets Manager; review before changing'
container['environment'] = [e for e in container.get('environment', []) if e['name'] != 'RPC_URLS'] + [{'name': 'RPC_URLS', 'value': rpc}]
for key in ['taskDefinitionArn', 'revision', 'status', 'requiresAttributes', 'compatibilities', 'registeredAt', 'registeredBy', 'deregisteredAt']:
    task.pop(key, None)
with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as f:
    json.dump(task, f); f.flush()
    revision = aws('ecs', 'register-task-definition', '--cli-input-json', 'file://' + f.name)['taskDefinition']['taskDefinitionArn']
aws('ecs', 'update-service', '--cluster', 'multyr-keeper', '--service', 'multyr-keeper-simulation', '--task-definition', revision, '--deployment-configuration', 'minimumHealthyPercent=0,maximumPercent=100,deploymentCircuitBreaker={enable=true,rollback=true}')
print('RPC rotation submitted:', revision, flush=True)
aws('ecs', 'wait', 'services-stable', '--cluster', 'multyr-keeper', '--services', 'multyr-keeper-simulation')
s = aws('ecs', 'describe-services', '--cluster', 'multyr-keeper', '--services', 'multyr-keeper-simulation')['services'][0]
assert s['taskDefinition'] == revision, 'Deployment rolled back'
print('RPC rotation stable; running tasks:', s['runningCount'])
