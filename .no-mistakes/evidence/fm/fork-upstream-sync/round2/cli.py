exec(open('.test-phase/live.py').read())
for name,fn in [('repeat-sync',merge),('send-guard',send),('codex-pin',account),('codex-quota',quota),('hermes-bash32-hook',hermes),('capacity-real-host',capacity),('stow-hook',stow)]:case(name,fn)
(E/'cli-results.json').write_text(json.dumps(results,indent=2))
raise SystemExit(any(r['result']!='pass' for r in results))
