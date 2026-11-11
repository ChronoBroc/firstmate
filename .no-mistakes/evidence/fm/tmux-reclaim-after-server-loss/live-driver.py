import os, subprocess as sp, pathlib as p, json, time, signal
R=p.Path.cwd(); L=R/'.reclaim-lab'; E=p.Path('~/.no-mistakes/evidence/01M75B3W5MHG8SWSN4T0B4ZMXC'); H=L/'home'; sock=R/'.s1'; sock2=R/'.s2'; ident='lr'+str(os.getpid()); env=os.environ.copy()
for k in list(env):
 if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'REX_')) or k in ('TMUX','TMUX_PANE','TERM_PROGRAM'): env.pop(k,None)
env.update(FM_HOME=str(H),FM_BACKEND='tmux',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
log=open(E/'live-transcript.log','w',buffering=1)
def run(args,ok=True,e=None):
 q=sp.run(list(map(str,args)),cwd=R,env=e or env,text=True,stdout=sp.PIPE,stderr=sp.STDOUT,timeout=120)
 log.write('$ '+' '.join(map(str,args))+'\n'+q.stdout+'\nexit='+str(q.returncode)+'\n')
 if ok and q.returncode: raise RuntimeError(q.stdout)
 return q

def tm(*a,other=False): return run(['tmux','-S',sock2 if other else sock,*a])
def connect():
 pid=tm('display-message','-p','#{pid}').stdout.strip(); env['TMUX']=f'{sock},{pid},0'
def record(session='original'):
 server=tm('display-message','-p','#{pid}:#{start_time}').stdout.strip()
 d=dict(window=f'{session}:fm-{ident}',endpoint_task_id=ident,worktree=str(L/'wt'),project=str(L/'proj'),harness='codex',kind='ship',mode='no-mistakes',yolo='off',model='default',effort='default',backend='tmux',tmux_socket=str(sock),tmux_server=server)
 meta.write_text(''.join(f'{k}={v}\n' for k,v in d.items())); return server

def control(verb='relaunch',ok=False): return run([R/'bin/fm-control.sh',ident,verb,*(['--note','Resume the preserved synthetic task after server loss.'] if verb=='relaunch' else [])],ok)
def guard(name):
 before=meta.read_bytes(); briefbefore=brief.read_bytes()
 for verb in ['exit','relaunch']:
  q=control(verb); assert q.returncode!=0,(name,q.stdout)
 q=run([R/'bin/fm-spawn.sh',ident,'--relaunch','--harness','codex'],False); assert q.returncode!=0
 assert meta.read_bytes()==before and brief.read_bytes()==briefbefore
 log.write('OBSERVED '+name+': exit, control relaunch, and spawn relaunch refused; record and brief unchanged\n')
def start(session):
 tm('-f','/dev/null','new-session','-d','-s',session,'-n','primary','-x','120','-y','40','-c',R)
 connect()
 tm('set-option','-g','default-command','/usr/bin/env PATH='+__import__('shlex').quote(env['PATH'])+' /bin/bash --noprofile --norc')
def stop():
 run(['tmux','-S',sock,'kill-server'],False); env.pop('TMUX',None)
 # Wait for the exact server process via a blocking subprocess before reusing socket.
 run(['python3','-c','import time; time.sleep(.3)'])
try:
 run([R/'bin/fm-lab-home.sh','create',H]); run(['git','init',L/'proj']); run(['git','-C',L/'proj','commit','--allow-empty','-m','seed']); run(['git','-C',L/'proj','worktree','add','-b','task-lab',L/'wt'])
 (L/'wt'/'preserved.txt').write_text('uncommitted work must survive\n')
 (H/'data'/ident).mkdir(); brief=H/'data'/ident/'brief.md'; brief.write_text('# Task\n## Captain\'s intent\nThis is a disposable recovery validation task. Do not use tools or modify files. Reply RECOVERY_READY and wait.\n## Firstmate spec\nDo not use tools or modify files. Reply RECOVERY_READY and wait.\n'); meta=H/'state'/f'{ident}.meta'
 start('original'); tm('new-window','-d','-t','original:','-n',f'fm-{ident}','-c',L/'wt'); old=record()
 tm('rename-session','-t','original','renamed'); guard('renamed session on surviving server'); tm('rename-session','-t','renamed','original')
 tm('new-session','-d','-s','moved'); tm('move-window','-s',f'original:fm-{ident}','-t','moved:'); guard('moved window on surviving server'); tm('move-window','-s',f'moved:fm-{ident}','-t','original:')
 saved=meta.read_text(); meta.write_text('\n'.join(x for x in saved.splitlines() if not x.startswith('tmux_'))+'\n'); tm('rename-window','-t',f'original:fm-{ident}','hidden'); guard('legacy record without server identity'); meta.write_text(saved); tm('rename-window','-t','original:hidden',f'fm-{ident}')
 tm('-f','/dev/null','new-session','-d','-s','foreign','-x','120','-y','40',other=True)
 env['TMUX']=f'{sock2},'+tm('display-message','-p','#{pid}',other=True).stdout.strip()+',0'; guard('window alive on another private server'); connect()
 meta.write_text(saved.replace(str(sock),str(R/'.missing-socket'))); tm('rename-window','-t',f'original:fm-{ident}','hidden'); guard('live recorded server unreachable at recorded socket'); meta.write_text(saved); tm('rename-window','-t','original:hidden',f'fm-{ident}')
 stop(); start('replacement'); tm('new-window','-d','-t','replacement:','-n',f'fm-{ident}','-c',L/'wt')
 q=control(); assert q.returncode!=0 and 'already exists' in q.stdout; assert meta.read_text()==saved; log.write('OBSERVED replacement collision refused without rebind\n'); tm('kill-window','-t',f'replacement:fm-{ident}')
 q=control('exit'); assert q.returncode==0 and 'endpoint-gone' in q.stdout
 q=control(ok=True)
 state=dict(x.split('=',1) for x in meta.read_text().splitlines() if '=' in x); assert state['window']==f'replacement:fm-{ident}'; assert state['tmux_server']!=old; assert state['worktree']==str(L/'wt'); assert (L/'wt'/'preserved.txt').read_text()=='uncommitted work must survive\n'
 log.write('PERSISTED RECOVERY RECORD\n'+meta.read_text()); tm('capture-pane','-p','-t',state['window'],'-S','-80'); log.write('OBSERVED fallback recovery preserves uncommitted file and worktree; new server identity published\n')
 def ready(target,label):
  deadline=time.monotonic()+65
  while time.monotonic()<deadline:
   q=tm('capture-pane','-p','-t',target,'-S','-100')
   if 'Trust this folder? Codex' in q.stdout and str(L/'wt') in q.stdout:
    (E/(label+'.txt')).write_text(q.stdout); return
   time.sleep(2)
  (E/(label+'.txt')).write_text(q.stdout)
  raise RuntimeError('real replacement did not render its folder access screen in the recorded worktree within 65 seconds')
 ready(state['window'],'fallback-worker')
 old2=state['tmux_server']; stop(); start('replacement')
 q=control(ok=True)
 state2=dict(x.split('=',1) for x in meta.read_text().splitlines() if '=' in x)
 assert state2['window']==state['window'] and state2['tmux_server']!=old2
 assert (L/'wt'/'preserved.txt').read_text()=='uncommitted work must survive\n'
 ready(state2['window'],'recorded-session-worker')
 log.write('OBSERVED recorded-session recovery: same worktree, preserved dirty file, new server identity, real Codex folder-access screen (no model response claimed)\n')
 (E/'live-state.json').write_text(json.dumps({'id':ident,'state':state,'old_server':old},indent=2))
except Exception as ex:
 log.write('DRIVER ERROR '+repr(ex)+'\n'); raise
finally:
 for s in [sock,sock2]: run(['tmux','-S',s,'kill-server'],False)
 log.close()
