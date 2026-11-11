import os, subprocess, pathlib, hashlib, json
root=pathlib.Path.cwd(); home=root/'.validation/home'; ev=pathlib.Path('~/.no-mistakes/evidence/01M764ZNGFSZSNBKA2PREBD0VQ')
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_SOCKET_PATH','TMUX']:
 env.pop(k,None)
env['FM_HOME']=str(home)
log=open(ev/'live-refusals.txt','w')
def run(args, expect=0):
 p=subprocess.run([str(x) for x in args],env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'EXIT {p.returncode}\n');log.flush()
 if expect is not None: assert p.returncode==expect, p.stdout
 return p
base=(home/'data/reuse/brief.md').read_text()
results=[]
for kind in ['ship','scout']:
 for fmt in ['recorded','legacy-brief','legacy-role']:
  id=f'{kind}-{fmt}'; d=home/'data'/id; d.mkdir()
  (d/'brief.md').write_text(base)
  if fmt=='recorded': (d/'finished-briefs').write_text(hashlib.sha256(base.encode()).hexdigest()+'\n')
  else: (d/'launch-brief.md').write_text(('# Current worker role contract\nSynthetic prior worker role contract\n\n' if fmt=='legacy-role' else '')+base+'\nPrior launch overlay\n')
  run([root/'bin/fm-tasks-axi.sh','add',id,'Prior task','--kind',kind])
  run([root/'bin/fm-tasks-axi.sh','done',id,'--no-prune'])
  run([root/'bin/fm-tasks-axi.sh','prune','--keep','0'])
  run([root/'bin/fm-tasks-axi.sh','add',id,'New unrelated task','--kind',kind])
  args=[root/'bin/fm-spawn.sh',id,root/'.validation/project','--backend','tmux']+(['--scout'] if kind=='scout' else ['--mode','local-only','--yolo','off'])
  p=run(args,None);assert p.returncode!=0
  assert ('brief of a finished task' if fmt=='recorded' else 'matches a previous launch') in p.stdout
  assert not (home/'state'/f'{id}.meta').exists()
  assert (d/'brief.md').read_text()==base
  show=run([root/'bin/fm-tasks-axi.sh','show',id]);assert 'state: queued' in show.stdout
  if fmt!='recorded':
   run([root/'bin/fm-captain-hold.sh','hold',id,'--reason','Approve this new item'])
   answer=root/'.validation/answer.txt';answer.write_text('Approve the new item.\n')
   run([root/'bin/fm-captain-hold.sh','answer',id,'--release','--decision-file',answer])
   p=run(args,None);assert p.returncode!=0 and 'matches a previous launch' in p.stdout
   assert not (home/'state'/f'{id}.meta').exists()
   assert 'state: queued' in run([root/'bin/fm-tasks-axi.sh','show',id]).stdout
  results.append({'kind':kind,'history':fmt,'result':'refused; queued; brief preserved; no metadata'})
log.write(json.dumps(results,indent=2)+'\n'); log.close()
print(json.dumps(results,indent=2))
