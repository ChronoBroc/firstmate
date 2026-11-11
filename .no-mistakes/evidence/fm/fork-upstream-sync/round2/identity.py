import pathlib, subprocess, os, signal, json
R=pathlib.Path.cwd(); W=R/'.test-phase'; E=pathlib.Path('~/.no-mistakes/evidence/01M75C1WF7H81D8WFBKR8YBNJK/round2')
module=W/'identity/tui_gateway'; module.mkdir(parents=True)
(module/'entry.py').write_text('import time; time.sleep(120)\n')
old=W/'hermes-before.sh'; old.write_text(subprocess.check_output(['git','show','HEAD^:bin/fm-hermes-process-lib.sh'],text=True))
env=os.environ.copy(); env['PYTHONPATH']=str(module.parent)
p=subprocess.Popen(['python3','-m','tui_gateway.entry'],env=env)
try:
 args=subprocess.check_output(['ps','-o','args=','-p',str(p.pid)],text=True).strip()
 # Wait for the exec transition using the process readiness represented by its argv.
 if 'tui_gateway.entry' not in args: raise RuntimeError(args)
 with (E/'hermes-real-process.log').open('w') as log:
  log.write('Real macOS process argv: '+args+'\n')
  for label,lib,expected in [('before',old,1),('after',R/'bin/fm-hermes-process-lib.sh',0)]:
   q=subprocess.run(['/bin/bash','-uc','. "$1"; fm_hermes_process_matches "$2"','_',str(lib),args],capture_output=True,text=True)
   log.write(f'{label}: executable process matcher exit={q.returncode}, expected={expected}\n'+q.stdout+q.stderr)
   assert q.returncode==expected
  for label,arg,expected in [('exact module',args,'agent'),('no argv','','other'),('lookalike payload','Python -c tui_gateway.entry','other')]:
   q=subprocess.run(['/bin/bash','-uc','. bin/fm-agent-process-lib.sh; fm_agent_process_classify Python "" "$1"','_',arg],capture_output=True,text=True)
   log.write(f'classify {label}: exit={q.returncode} output={q.stdout.strip()} expected={expected}\n'+q.stderr)
   assert q.returncode==0 and q.stdout.strip()==expected
finally:
 p.terminate(); p.wait(timeout=10)
print('Hermes real process: before-fix rejection, after-fix recognition, negative controls verified; child reaped')
