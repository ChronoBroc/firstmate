import os, pathlib, subprocess, json, shutil, traceback
R=pathlib.Path.cwd(); W=R/'.test-phase'; E=pathlib.Path('~/.no-mistakes/evidence/01M75C1WF7H81D8WFBKR8YBNJK')
env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_')) or k in ('TMUX','CODEX_HOME','CLAUDE_CONFIG_DIR','QUOTA_AXI_SNAPSHOT'): env.pop(k,None)
env.update(HOME=str(W/'home'),TMPDIR=str(W/'tmp'),XDG_CONFIG_HOME=str(W/'home/config'),XDG_CACHE_HOME=str(W/'home/cache'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Fixture',GIT_COMMITTER_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.test',GIT_COMMITTER_EMAIL='fixture@example.test')
results=[]; log=None

def run(args, *, extra=None, inp=None, cwd=R, codes=(0,), timeout=50):
 global log
 e=env.copy(); e.update(extra or {})
 p=subprocess.run([str(x) for x in args],input=inp,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,cwd=cwd,env=e,timeout=timeout)
 log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'\n[exit {p.returncode}]\n');log.flush()
 assert p.returncode in codes, (args,p.returncode,p.stdout)
 return p.stdout

def case(name,fn):
 global log
 with (E/(name+'.log')).open('w') as log:
  try: fn(); results.append({'name':name,'result':'pass'}); print(name,'PASS',flush=True)
  except Exception as ex: traceback.print_exc(file=log); results.append({'name':name,'result':'fail','error':str(ex)}); print(name,'FAIL',str(ex),flush=True)
 (W/'live-results.json').write_text(json.dumps(results,indent=2))

def home(name):
 h=W/name
 run(['bin/fm-lab-home.sh','create',h])
 return h

def merge():
 for ref in ['734321ddc0a8d3f8488ea7dd4cdee0900bd7ed7f','64254de47a2989add6412949e98c36e3964b24aa','b1e5da8d','1fadd20b','15a419a9']:
  run(['git','merge-base','--is-ancestor',ref,'1eee0c669d5b5d670f0969d855ed513000b791f6'])
 repo=W/'sync'; repo.mkdir()
 def g(*a):return run(['git',*a],cwd=repo)
 g('init','-b','main');(repo/'parent.txt').write_text('parent baseline\n');g('add','.');g('commit','-m','base');g('branch','parent')
 (repo/'fork-fix.txt').write_text('fork fix survives\n');g('add','.');g('commit','-m','fork fix');fix=g('rev-parse','HEAD').strip()
 g('switch','parent');(repo/'parent.txt').write_text('upstream update one\n');g('commit','-am','upstream one');first=g('rev-parse','HEAD').strip()
 g('switch','main');g('merge','parent','-m','sync one');g('merge-base','--is-ancestor',fix,'HEAD');g('merge-base','--is-ancestor',first,'HEAD')
 g('switch','parent');(repo/'parent.txt').write_text('upstream update two\n');g('commit','-am','upstream two');second=g('rev-parse','HEAD').strip()
 g('switch','main');g('merge','parent','-m','sync two');g('merge-base','--is-ancestor',fix,'HEAD');g('merge-base','--is-ancestor',second,'HEAD');g('log','--graph','--oneline','--all')
 assert (repo/'fork-fix.txt').read_text()=='fork fix survives\n'; assert (repo/'parent.txt').read_text()=='upstream update two\n'
 log.write('Observed files after second sync: fork fix survives; upstream update two. Both histories remain ancestors.\n')

def send():
 h=home('send');ex={'FM_HOME':str(h),'FM_BACKEND':'tmux','TMUX':str(W/'absent.sock')+',0,0'}
 (h/'state/t1.meta').write_text('window=lab:fm-t1\nkind=ship\nharness=claude\n')
 out=run(['bin/fm-send.sh','t1','--typo','hello'],extra=ex,codes=(1,));assert 'unknown flag' in out and 'nothing was sent' in out
 out=run(['bin/fm-send.sh','t1','--','--typo','hello'],extra=ex,codes=(0,1));assert 'unknown flag' not in out
 files=list((h/'state').rglob('*')); messages=[]
 for f in files:
  if f.is_file() and f.suffix in ('.json','.jsonl','.msg'): 
   text=f.read_text();log.write(str(f.relative_to(h))+': '+text+'\n');messages.append(text)
 assert any('--typo hello' in s for s in messages), 'literal retry was not persisted'

def account():
 h=home('pin');stored=W/'codex-stored'; empty=W/'codex-empty';stored.mkdir();empty.mkdir();(stored/'auth.json').write_text('{"OPENAI_API_KEY":"sk-fm-live-synthetic"}');(stored/'auth.json').chmod(0o600)
 run(['codex','login','status'],extra={'CODEX_HOME':str(stored)})
 script='. bin/fm-worker-account-lib.sh; fm_worker_account_check codex "$1" "$1" codex'
 run(['/bin/bash','-c',script,'_',stored],extra={'CODEX_ACCESS_TOKEN':'fm-live-synthetic'})
 run(['/bin/bash','-c',script,'_',empty],codes=(1,))
 (h/'config/codex-account').write_text(str(stored)+'\n')
 run(['/bin/bash','-c','. bin/fm-worker-account-lib.sh; fm_worker_account_resolve codex "$1" config/codex-account','_',h/'config'])
 (h/'config/codex-account').write_text('../escape\n')
 run(['/bin/bash','-c','. bin/fm-worker-account-lib.sh; fm_worker_account_resolve codex "$1" config/codex-account','_',h/'config'],codes=(1,2))

def quota():
 h=home('quota'); store=W/'quota-empty';store.mkdir(); (h/'config/codex-account').write_text(str(store)+'\n')
 ex={'FM_HOME':str(h),'FM_BACKEND':'herdr','QUOTA_AXI_SNAPSHOT':str(W/'poison.json')}
 (W/'poison.json').write_text('{"not":"a quota snapshot"}')
 out=run(['bin/fm-codex-account-quota.sh','--model','gpt-6-astra'],extra=ex,timeout=80)
 assert str(store) in out and 'uncertainty' in out and ('missing' in out.lower() or 'unavailable' in out.lower() or 'could not' in out.lower())
 (h/'config/codex-account').write_text('../bad\n');run(['bin/fm-codex-account-quota.sh'],extra=ex,codes=(2,))

def hermes():
 h=home('hermes');state=h/'state'; (state/'worker.hermes-hooks').mkdir()
 gen=run(['bin/fm-busy-event.sh','arm',state,'worker']).strip()
 payload=json.dumps({'extra':{'platform':'tui','turn_id':'main'}})
 run(['/bin/bash','-u','bin/fm-hermes-hook.sh',state,'worker',gen,'busy'],inp=payload)
 busy=(state/'worker.busy-state').read_text();log.write('persisted busy record: '+busy+'\n');assert 'busy' in busy and 'hermes-hook' in busy
 run(['/bin/bash','-u','bin/fm-hermes-hook.sh',state,'worker',gen,'idle'],inp=payload)
 log.write('persisted idle record: '+(state/'worker.busy-state').read_text()+'\n');assert (state/'worker.turn-ended').exists()
 run(['/bin/bash','-uc','. bin/fm-hermes-process-lib.sh; fm_hermes_process_matches'],codes=(1,))


def capacity():
 h=home('capacity');ex={'FM_HOME':str(h),'FM_LANE_CAPACITY_PUBLISH_INTERVAL':'0'}
 (h/'config/lane-capacity').write_text('auto\nmax-lanes 2\nadmit-spawns\n')
 d=json.loads(run(['bin/fm-capacity.sh','--json'],extra=ex));assert d['cap']['mode']=='auto';assert 0<=d['verdict']['free_lanes']<=2
 run(['bin/fm-capacity.sh','--publish'],extra=ex);log.write('persisted capacity: '+(h/'state/lane-capacity.json').read_text()+'\n');assert (h/'state/lane-footprint.json').exists()
 for i in range(2):(h/f'state/lane{i}.meta').write_text('kind=ship\nharness=codex\n')
 run(['bin/fm-capacity.sh','--spawn-gate'],extra=ex,codes=(75,));d=json.loads(run(['bin/fm-capacity.sh','--json'],extra=ex));assert not d['verdict']['admit'] and d['verdict']['free_lanes']==0


def stow():
 h=home('stow');(h/'bin').mkdir();shutil.copyfile(R/'AGENTS.md',h/'AGENTS.md');run(['git','init'],cwd=h)
 transcript=h/'transcript.jsonl';transcript.write_text(json.dumps({'message':{'usage':{'input_tokens':1500}}})+'\n')
 payload=json.dumps({'session_id':'synthetic-stop','transcript_path':str(transcript),'stop_hook_active':False})
 ex={'FM_HOME':str(h),'FM_ROOT_OVERRIDE':str(h)}
 assert not run(['bin/fm-stow-guard.sh'],extra=ex,inp=payload).strip()
 (h/'config/stow-guard').write_text('tokens=1000\n')
 out=run(['bin/fm-stow-guard.sh'],extra=ex,inp=payload);assert json.loads(out)['decision']=='block'
 assert not run(['bin/fm-stow-guard.sh'],extra=ex,inp=payload).strip()
 transcript.write_text(json.dumps({'message':{'usage':{'input_tokens':100}}})+'\n');assert not run(['bin/fm-stow-guard.sh'],extra=ex,inp=payload).strip()
 transcript.write_text(json.dumps({'message':{'usage':{'input_tokens':1500}}})+'\n');out=run(['bin/fm-stow-guard.sh'],extra=ex,inp=payload);assert json.loads(out)['decision']=='block'
 log.write('persisted hook state: '+(h/'state/.stow-guard.json').read_text()+'\n')

for name,fn in [('send-guard',send),('hermes-bash32-hook',hermes)]:case(name,fn)
