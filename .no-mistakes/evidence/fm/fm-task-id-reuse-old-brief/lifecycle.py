import os,subprocess,pathlib,hashlib,json
r=pathlib.Path.cwd();h=r/'.validation/home';ev=pathlib.Path('~/.no-mistakes/evidence/01M764ZNGFSZSNBKA2PREBD0VQ');log=open(ev/'live-lifecycle.txt','w')
e=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_BACKEND']: e.pop(k,None)
e['FM_HOME']=str(h);e['TREEHOUSE_ROOT']=str(r/'.validation/pool');e['DISABLE_AUTOUPDATER']='1'
pid=subprocess.check_output(['tmux','-S',str(r/'.validation/s'),'display-message','-p','#{pid}'],text=True).strip();e['TMUX']=f'{r}/.validation/s,{pid},0'
def run(a,rc=0):
 p=subprocess.run([str(x) for x in a],cwd=r,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 log.write('$ '+' '.join(str(x) for x in a)+'\n'+p.stdout+f'EXIT {p.returncode}\n');log.flush()
 if rc is not None:assert p.returncode==rc,p.stdout
 return p
for kind,id in [('ship','reuse'),('scout','live-scout')]:
 d=h/'data'/id
 spawn=[r/'bin/fm-spawn.sh',id,r/'.validation/project','--backend','tmux']+(['--scout'] if kind=='scout' else ['--mode','local-only','--yolo','off'])
 if kind=='scout':
  run([r/'bin/fm-tasks-axi.sh','add',id,'Disposable scout lifecycle','--kind','scout'])
  run([r/'bin/fm-brief.sh',id,'project','--scout'])
  p=d/'brief.md';p.write_text(p.read_text().replace('{TASK}','Print SCOUT-TOKEN and await further instructions.').replace('{FIRSTMATE_SPEC}','Make no changes. This is a disposable launch check.'))
  run(spawn)
 before=(d/'brief.md').read_bytes()
 # The ship has a checksum for an older brief, from the prior scenario. Retain must not append this current brief.
 old_records=(d/'finished-briefs').read_bytes() if (d/'finished-briefs').exists() else None
 run([r/'bin/fm-captain-hold.sh','hold',id,'--reason','Continue this same task after approval'])
 run([r/'bin/fm-teardown.sh',id,'--force'])
 assert not (h/'state'/f'{id}.meta').exists()
 assert 'state: queued' in run([r/'bin/fm-tasks-axi.sh','show',id]).stdout
 assert ((d/'finished-briefs').read_bytes() if (d/'finished-briefs').exists() else None)==old_records
 run([r/'bin/fm-captain-hold.sh','answer',id,'--release','--decision-file',r/'.validation/answer.txt'])
 p=run(spawn,None)
 if old_records is None:
  assert p.returncode!=0 and 'same retained task rather than a new item' in p.stdout
  assert (d/'brief.md').read_bytes()==before
  (d/'launch-brief.md').unlink()
  log.write('Operator confirms same retained item and removes only its launch-brief.md as instructed.\n')
  run(spawn)
 else: assert p.returncode==0,p.stdout
 assert 'state: in_flight' in run([r/'bin/fm-tasks-axi.sh','show',id]).stdout
 assert (d/'brief.md').read_bytes()==before
 run(['tmux','-S',r/'.validation/s','capture-pane','-p','-t',f'primary:fm-{id}','-S','-45'])
 run([r/'bin/fm-teardown.sh',id,'--force'])
 assert hashlib.sha256(before).hexdigest() in (d/'finished-briefs').read_text().splitlines()
 assert 'state: done' in run([r/'bin/fm-tasks-axi.sh','show',id]).stdout
 run([r/'bin/fm-tasks-axi.sh','prune','--keep','0'])
 run([r/'bin/fm-tasks-axi.sh','add',id,'Unrelated replacement','--kind',kind])
 p=run(spawn,None);assert p.returncode!=0 and 'brief of a finished task' in p.stdout
 assert not (h/'state'/f'{id}.meta').exists()
 assert 'state: queued' in run([r/'bin/fm-tasks-axi.sh','show',id]).stdout
 log.write(f'VERIFIED: real {kind} retain, continuation, close, prune, re-add, and stale-brief refusal.\n');log.flush()
log.close();print('Live lifecycle checks completed.')
