exec(open('.test-phase/live.py').read().split("for name,fn in [('send-guard'")[0])
import http.server, threading, socket, functools

def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]

def lavish():
 h=home('lavish');web=W/'site';web.mkdir(exist_ok=True)
 (web/'index.html').write_text('''<!doctype html><html><head><title>Disposable storefront</title><style>body{margin:0;font:20px system-ui;background:#eef2f6;color:#17334a}main{max-width:950px;margin:70px auto;padding:50px;background:white;border-radius:20px}h1{font-size:46px}button{background:#126b69;color:white;border:0;padding:15px 25px;border-radius:8px;font:inherit}.card{padding:24px;background:#dcf1e9;border-radius:12px}</style></head><body><main><h1>Harbor supply</h1><p>A disposable local page for the fork sync validation.</p><div class="card"><h2>Weekend kit</h2><p>Ready for your next outing.</p><button id="buy" onclick="document.body.dataset.unsafe='executed'">View kit</button></div><p id="dynamic">Loading</p></main><script>document.querySelector('#dynamic').textContent='Rendered content captured';document.styleSheets[0].insertRule('.card{border:3px solid #17836f}',0);</script></body></html>''')
 handler=functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(web));server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler);thread=threading.Thread(target=server.serve_forever);thread.start()
 url=f'http://127.0.0.1:{server.server_port}/index.html';sid='';snap=None
 env.update(FM_HOME=str(h),FM_PROCEVENT_CLAIM_ROOT=str(h/'claims'),LAVISH_AXI_STATE_DIR=str(h/'lavish-server'),LAVISH_AXI_PORT=str(port()),LAVISH_AXI_HOST='127.0.0.1',LAVISH_AXI_NO_OPEN='1',CHROME_DEVTOOLS_AXI_SESSION='fm-test-url-capture',FM_LAVISH_URL_BROWSER_SESSION='fm-test-url-capture',CHROME_DEVTOOLS_AXI_USER_DATA_DIR=str(h/'chrome-profile'),CHROME_DEVTOOLS_AXI_AUTO_CONNECT='0')
 env.pop('CHROME_DEVTOOLS_AXI_BROWSER_URL',None);env.pop('CHROME_DEVTOOLS_AXI_MCP_SERVER_URL',None)
 (h/'data/projects.md').write_text('# Projects\n\n- storefront [direct-PR] - Disposable storefront\n')
 (h/'config/lavish-url-domains').write_text(f'127.0.0.1:{server.server_port} storefront\n')
 try:
  out=run(['bin/fm-lavish-url.sh','snapshot',url],timeout=240)
  assert 'armed:' in out and 'route: project' in out
  snap=pathlib.Path(next(x[10:] for x in out.splitlines() if x.startswith('snapshot: ')))
  meta=json.loads(snap.with_suffix('.meta.json').read_text());sid=meta['source_id'];shutil.copyfile(snap,E/'lavish-desktop.html');shutil.copyfile(snap.with_suffix('.meta.json'),E/'lavish-desktop-meta.json')
  assert run(['bin/fm-lavish-url.sh','path',url]).strip()==str(snap)
  review_session='fm-test-url-review';env['CHROME_DEVTOOLS_AXI_SESSION']=review_session
  run(['chrome-devtools-axi','open',snap.as_uri()],timeout=100)
  run(['chrome-devtools-axi','screenshot',str(E/'lavish-desktop.png')],timeout=60)
  out=run(['chrome-devtools-axi','eval',"() => {document.querySelector('#buy').click();return JSON.stringify({text:document.querySelector('#dynamic').textContent,unsafe:document.body.dataset.unsafe||null,border:getComputedStyle(document.querySelector('.card')).borderTopWidth,reviewLayer:!!document.querySelector('[data-fm-lavish-url]')});}"])
  assert 'Rendered content captured' in out and 'executed' not in out and '3px' in out
  run(['chrome-devtools-axi','emulate','--viewport','390x844x1']);run(['chrome-devtools-axi','screenshot',str(E/'lavish-mobile-render.png')])
  run(['chrome-devtools-axi','stop']);env['CHROME_DEVTOOLS_AXI_SESSION']='fm-test-url-capture'
  run(['bin/fm-procevent.sh','retire',sid]);sid=''
  run(['lavish-axi','end',snap])
  out=run(['bin/fm-lavish-url.sh','snapshot','file:///etc/passwd'],codes=(1,2));assert 'only http and https' in out
 finally:
  for record in (h/'state/procevent').glob('*.source'):
   run(['bin/fm-procevent.sh','retire',record.stem],codes=(0,1,2),timeout=40)
  if sid:run(['bin/fm-procevent.sh','retire',sid],codes=(0,1,2),timeout=40)
  for session in ['fm-test-url-capture','fm-test-url-review']:
   run(['chrome-devtools-axi','stop'],extra={'CHROME_DEVTOOLS_AXI_SESSION':session},codes=(0,1),timeout=40)
  run(['lavish-axi','stop'],codes=(0,1),timeout=40)
  server.shutdown();server.server_close();thread.join()
case('lavish-local-capture',lavish)
