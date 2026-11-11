import os, subprocess, pathlib, json
root=pathlib.Path.cwd(); home=root/'.live-send/home'; evidence=pathlib.Path('/Users/broc-macmini/.no-mistakes/evidence/01M74G25HQQ2SVDP4FMZM7K11S'); log=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k.startswith('HERDR_') or k.startswith('TASKS_AXI_'): env.pop(k)
env.update(FM_HOME=str(home),FM_BACKEND='tmux',FM_SEND_SETTLE='0',TMUX=subprocess.check_output(['tmux','-S',str(root/'.s'),'display-message','-p','#{socket_path},#{pid},0'],text=True).strip())
(home/'state/t1.meta').write_text('window=lab:fm-t1\nbackend=tmux\nkind=ship\nharness=claude\n')
def run(args,base=False,code=0):
 p=subprocess.run(['bash',str(root/('bin/.baseline-send.sh' if base else 'bin/fm-send.sh'))]+args,env=env,text=True,capture_output=True)
 log.append({'version':'base' if base else 'target','args':args,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
 (evidence/'live-send.json').write_text(json.dumps(log,indent=2))
 assert p.returncode==code,(args,p.returncode,p.stderr)
 return p
# Durable inbox is the product delivery contract. The real tmux endpoint receives its doorbell.
for flag in ['--file','--help']: run(['t1',flag],base=True)
for p in sorted((home/'state/t1.inbox').glob('*.msg')):
 log.append({'baseline_record':p.name,'content':p.read_text()}); assert p.read_text().rstrip().endswith(('--file','--help'))
count=lambda:len(list((home/'state/t1.inbox').glob('*.msg')))
for args in [['--file','/tmp/a b.md'],['--help'],['-f'],['--file=x'],['--force','restart']]:
 n=count(); run(['t1']+args,code=1); assert count()==n
run(['lab:fm-t1','--help'],code=1)
(home/'state/t1.status').write_text('needs-decision [key=k]: choose\n')
run(['t1','--resolve-key','k','--help'],code=1)
assert (home/'state/t1.status').read_text()=='needs-decision [key=k]: choose\n'
for args,body in [(['--','--key','Enter'],'--key Enter'),(['--','--help'],'--help'),(['- item\n- next'],'- item\n- next'),(['--- heading'],'--- heading'),(['-1'],'-1'),(['--help me with this'],'--help me with this'),(['normal','--file'],'normal --file')]:
 n=count();run(['t1']+args);assert count()==n+1
 p=sorted((home/'state/t1.inbox').glob('*.msg'))[-1]; text=p.read_text();assert text.rstrip().endswith(body)
 log.append({'delivered_record':p.name,'content':text})
n=count();run(['t1','--'],code=1);assert count()==n
p=run(['t1','--file','/tmp/a b.md'],code=1)
resend=p.stderr.strip().splitlines()[-1].strip()
p=subprocess.run(['bash','-c',resend],env=env,text=True,capture_output=True)
log.append({'printed_resend':resend,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr});assert p.returncode==0
record=sorted((home/'state/t1.inbox').glob('*.msg'))[-1];assert record.read_text().rstrip().endswith('--file /tmp/a b.md');log.append({'resend_record':record.read_text()})
run(['t1','--resolve-key','k','--','--help']);assert 'resolved' in (home/'state/t1.status').read_text()
log.append({'resolved_status':(home/'state/t1.status').read_text()})
run(['t1','--key','Enter'])
(home/'state/mate.meta').write_text(f'window=lab:fm-t1\nbackend=tmux\nkind=secondmate\nmode=secondmate\nharness=claude\nhome={home}\n')
run(['mate','--fire-and-forget','0123456789abcdef','--help'],code=1)
assert not (home/'state/mate.inbox').exists();assert not list((home/'state/pending-replies').glob('*'))
run(['--help'])
log.append({'tmux_pane':subprocess.check_output(['tmux','-S',str(root/'.s'),'capture-pane','-p','-t','lab:fm-t1'],text=True)})
(evidence/'live-send.json').write_text(json.dumps(log,indent=2));print('All live CLI assertions passed; transcript:',evidence/'live-send.json')
