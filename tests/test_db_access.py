"""Exercise lifecycle scripts with failing/empty/partial AWS and Terraform responses.
No credentials, network, or infrastructure changes are used.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONNECTION = dict(version=1, account_id='123456789012', region='us-east-1',
                  name_prefix='congenia', environment='prod', vpc_id='vpc-1',
                  subnet_id='subnet-1', data_sg_id='sg-data',
                  db_host='test.us-east-1.rds.amazonaws.com', db_port=5432, db_name='congenia')
FAKE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]; tool=Path(sys.argv[0]).name
state_path=Path(os.environ['FAKE_STATE']); state=json.loads(state_path.read_text())
with open(os.environ['FAKE_LOG'], 'a') as log: log.write(json.dumps([tool]+args)+'\n')
def save(): state_path.write_text(json.dumps(state))
def emit(obj): print(json.dumps(obj)); sys.exit(0)
def text(s=''): print(s); sys.exit(0)
def die(): print('AccessDenied: simulated API failure', file=sys.stderr); sys.exit(3)
if tool in ('sleep','session-manager-plugin'): text()
if tool=='terraform':
    where=args.pop(0) if args[0].startswith('-chdir=') else os.getcwd(); op=args.pop(0)
    if state.get('tf_error')==op: die()
    if op=='init': text()
    if op=='state' and state.get('core_rules'):
        if args[0]=='list': text('module.network.aws_security_group.data\nmodule.network.aws_security_group.app')
        if args[-1].endswith('.data'): text('id = "sg-data"')
        if args[-1].endswith('.app'): text('id = "sg-app"')
        die()
    if op=='import': text()
    if op=='state': text('\n'.join('module.network.aws_vpc_security_group_'+k+'_rule.'+v for k,v in [('ingress','data_postgres'),('ingress','data_redis'),('egress','data_vpc')]))
    if op=='output':
        if args[-1]=='region': text('us-east-1')
        if args[-1]=='vpc_id': text('vpc-1')
        if args[-1]=='db_access_context': emit(state['context'])
        emit({'connection':state['context']})
    if op=='plan': text('Plan: access only')
    if op=='show':
        if any('tfplan' in a for a in args): emit({'resource_changes':[{'change':{'actions':['delete','create']}}] if state.get('replace') else []})
        emit({'values':{'root_module':{'resources':[{'mode':'managed','address':'module.db_access.aws_instance.relay'}] if state.get('managed') else []}}})
    if op=='apply': state.update(managed=True, node=state.get('node') or 'running'); save(); text()
    if op=='destroy': state.update(managed=False,node=None); save(); text()
    die()
if args[:1]==['--region']: args=args[2:]
service,op=args[:2]; key=service+' '+op
if state.get('error')==key: die()
if key=='sts get-caller-identity': text(state.get('account','123456789012'))
if key=='ec2 describe-instances':
    nodes=[] if not state.get('node') else [{'InstanceId':'i-test','State':{'Name':state['node']}}]
    if state.get('duplicate'): nodes=nodes*2
    emit({'Reservations':[{'Instances':nodes}]})
if key=='ec2 describe-vpcs': text('10.0.0.0/16')
if key=='ec2 describe-security-group-rules' and state.get('core_rules'):
    rules=[{'SecurityGroupRuleId':'sgr-'+str(port),'IsEgress':False,'IpProtocol':'tcp','FromPort':port,'ToPort':port,'ReferencedGroupInfo':{'GroupId':'sg-app'}} for port in (5432,6379)]
    rules.append({'SecurityGroupRuleId':'sgr-vpc','IsEgress':True,'IpProtocol':'-1','CidrIpv4':'10.0.0.0/16'})
    if state.get('ambiguous'): rules.append(rules[0])
    emit({'SecurityGroupRules':rules})
if key=='ec2 start-instances': state['node']='running'; save(); emit({})
if key=='ec2 stop-instances': state['node']='stopping'; save(); emit({})
if key=='ec2 wait':
    if 'instance-stopped' in args: state['node']='stopped'
    else: state['node']='running'
    save(); text()
if key=='ssm describe-instance-information':
    if '--output' in args and args[args.index('--output')+1]=='text': text('Online')
    emit({'InstanceInformationList':[{'PingStatus':'Online'}]})
if key=='ssm start-session': emit({})
empty={'ec2 describe-volumes':('Volumes', []),'ec2 describe-security-groups':('SecurityGroups', []),
       'ec2 describe-security-group-rules':('SecurityGroupRules', []),'ec2 describe-snapshots':('Snapshots', []),
       'ec2 describe-network-interfaces':('NetworkInterfaces', []),'iam list-roles':('Roles', []),
       'iam list-instance-profiles':('InstanceProfiles', []),'iam list-policies':('Policies', []),
       'ssm list-documents':('DocumentIdentifiers', [])}
if key in empty:
    k,v=empty[key]
    if key=='ec2 describe-volumes' and state.get('leftover'): v=[{'VolumeId':'vol-leftover'}]
    if key=='iam list-roles' and state.get('orphan_role'): v=[{'RoleName':'congenia-prod-db-access'}]
    emit({k:v})
# The global audit uses --query/--output text for many services.
if '--output' in args and args[args.index('--output')+1]=='text': text()
die()
'''


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'; self.bin.mkdir()
        for name in ('aws', 'terraform', 'sleep', 'session-manager-plugin'):
            p=self.bin/name; p.write_text(FAKE); p.chmod(0o755)
        self.stack=self.base/'stack'; self.stack.mkdir()
        self.log=self.base/'log'
        self.state=self.base/'state.json'
        self.fixture={'context':CONNECTION}
        self.env={**os.environ, 'PATH':str(self.bin)+os.pathsep+os.environ['PATH'],
                  'FAKE_STATE':str(self.state), 'FAKE_LOG':str(self.log),
                  'DB_ACCESS_DIR':str(self.stack), 'DB_ACCESS_CORE_DIR':str(self.base/'core'),
                  'TERRAFORM':str(self.bin/'terraform'), 'AWS_REGION':'us-east-1',
                  'TF_VAR_name_prefix':'congenia','TF_VAR_environment':'prod'}
        self.env.pop('CONFIRM_DESTROY', None)

    def run_script(self, action, **values):
        self.fixture.update(values); self.state.write_text(json.dumps(self.fixture))
        return subprocess.run(['bash', str(ROOT/'scripts/db-access.sh'), action], env=self.env,
                              text=True,capture_output=True,timeout=20)

    def calls(self):
        return [json.loads(s) for s in self.log.read_text().splitlines()]

    def test_status_absent_never_mutates(self):
        r=self.run_script('status'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('Estado: ausente',r.stdout)
        self.assertTrue(all('terraform' != c[0] for c in self.calls()))
        self.assertFalse(any('start-instances' in c or 'stop-instances' in c for c in self.calls()))

    def test_status_partial_without_instance(self):
        r=self.run_script('status',orphan_role=True)
        self.assertEqual(r.returncode,0,r.stderr); self.assertIn('incompleto',r.stdout)

    def test_access_denied_is_not_absence(self):
        r=self.run_script('verify',error='iam list-roles')
        self.assertNotEqual(r.returncode,0); self.assertIn('AccessDenied',r.stderr)
        self.assertNotIn('ausente en AWS',r.stdout)

    def test_stopped_instance_counts_as_survivor(self):
        r=self.run_script('verify',node='stopped')
        self.assertNotEqual(r.returncode,0); self.assertIn('i-test',r.stdout)

    def test_stop_is_idempotent_and_waits(self):
        r=self.run_script('stop',node='running'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(self.state.read_text())['node'],'stopped')
        r=self.run_script('stop',node='stopped'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(sum('stop-instances' in c for c in self.calls()),1)

    def test_duplicate_instances_fail_without_mutation(self):
        r=self.run_script('stop',node='running',duplicate=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(any('stop-instances' in c for c in self.calls()))

    def test_up_starts_stopped_instance_only_in_access_stack(self):
        r=self.run_script('up',node='stopped',managed=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(any('start-instances' in c for c in self.calls()))
        for c in self.calls():
            if c[0]=='terraform' and any(x in c for x in ('plan','apply','destroy')):
                self.assertIn('-chdir='+str(self.stack),c)

    def test_replacement_is_blocked_before_apply(self):
        r=self.run_script('up',replace=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(any('apply' in c for c in self.calls()))

    def test_destroy_requires_scoped_confirmation(self):
        r=self.run_script('destroy',node='running',managed=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_destroy_empty_stack_verifies_aws(self):
        self.env['CONFIRM_DESTROY']='destroy-congenia-db-access'
        r=self.run_script('destroy'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('eliminado y verificado',r.stdout)
        self.assertFalse(any('destroy' in c for c in self.calls()))

    def test_destroy_detects_orphan_volume_and_keeps_contract(self):
        self.env['CONFIRM_DESTROY']='destroy-congenia-db-access'
        config=self.stack/'connection.auto.tfvars.json'; config.write_text(json.dumps({'connection':CONNECTION}))
        r=self.run_script('destroy',managed=True,node='running',leftover=True)
        self.assertNotEqual(r.returncode,0,r.stderr); self.assertTrue(config.exists())
        self.assertIn('vol-leftover',r.stdout)

    def test_account_mismatch_fails_before_writes(self):
        (self.stack/'connection.auto.tfvars.json').write_text(json.dumps({'connection':CONNECTION}))
        r=self.run_script('up',account='999999999999')
        self.assertNotEqual(r.returncode,0); self.assertEqual(len(self.calls()),1)

    def test_tunnel_never_autostarts_and_uses_fixed_document(self):
        r=self.run_script('tunnel',node='stopped'); self.assertNotEqual(r.returncode,0)
        r=self.run_script('tunnel',node='running'); self.assertEqual(r.returncode,0,r.stderr)
        call=next(c for c in self.calls() if 'start-session' in c)
        self.assertIn('congenia-prod-db-access',call)
        self.assertNotIn('host',call[call.index('--parameters')+1])

    def test_destroy_recovers_contract_without_reading_core(self):
        self.env['CONFIRM_DESTROY']='destroy-congenia-db-access'
        r=self.run_script('destroy',node='stopped',managed=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.stack/'connection.auto.tfvars.json').exists())
        self.assertFalse(any('db_access_context' in c for c in self.calls()))

    def test_migration_imports_existing_rule_ids_only(self):
        self.fixture['core_rules']=True; self.state.write_text(json.dumps(self.fixture))
        r=subprocess.run(['bash',str(ROOT/'scripts/migrate-data-sg-rules.sh'),str(self.base/'core'),'--apply'],
                         env=self.env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        imports=[c for c in self.calls() if 'import' in c]
        self.assertEqual({c[-1] for c in imports},{'sgr-5432','sgr-6379','sgr-vpc'})
        self.assertFalse(any('apply' in c or 'authorize-security-group-ingress' in c for c in self.calls()))

    def test_migration_rejects_ambiguous_rules_before_import(self):
        self.fixture.update(core_rules=True,ambiguous=True); self.state.write_text(json.dumps(self.fixture))
        r=subprocess.run(['bash',str(ROOT/'scripts/migrate-data-sg-rules.sh'),str(self.base/'core'),'--apply'],
                         env=self.env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(any('import' in c for c in self.calls()))

    def test_main_destroy_stops_if_access_cleanup_fails(self):
        (self.base/'Makefile').write_text((ROOT/'Makefile').read_text())
        (self.base/'scripts').mkdir()
        fail=self.base/'scripts/db-access.sh'; fail.write_text('#!/bin/sh\nexit 7\n'); fail.chmod(0o755)
        self.state.write_text(json.dumps(self.fixture))
        r=subprocess.run(['make','destroy','ENV=aws','CONFIRM_DESTROY=destroy-congenia-aws'],
                         cwd=self.base,env=self.env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(self.log.exists(), 'No debe inicializar ni aplicar el entorno principal')

    def test_nuke_aborts_before_shared_when_main_state_read_fails(self):
        (self.base/'Makefile').write_text((ROOT/'Makefile').read_text())
        (self.base/'envs/aws').mkdir(parents=True)
        self.fixture['tf_error']='show'; self.state.write_text(json.dumps(self.fixture))
        r=subprocess.run(['make','nuke','CONFIRM_DESTROY=destroy-congenia-todo'],
                         cwd=self.base,env=self.env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0)
        self.assertFalse(any('apply' in c or 'destroy' in c for c in self.calls()))

    def test_global_audit_does_not_mask_api_failure(self):
        self.fixture['error']='ec2 describe-volumes'; self.state.write_text(json.dumps(self.fixture))
        r=subprocess.run(['bash',str(ROOT/'scripts/verify-teardown.sh')],env=self.env,text=True,capture_output=True)
        self.assertNotEqual(r.returncode,0)
        self.assertNotIn('La cuenta quedo limpia',r.stdout)

if __name__=='__main__': unittest.main()
