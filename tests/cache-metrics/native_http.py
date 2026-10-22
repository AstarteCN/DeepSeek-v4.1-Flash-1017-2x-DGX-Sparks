"""Bounded HTTP accounting checks against the real native server with a scripted CPU engine."""
from pathlib import Path
import concurrent.futures,hashlib,http.client,json,os,re,selectors,signal,subprocess,time
E=Path('/work/engine');O=Path('/work/results-feature');binary=E/'zig-out/server/fake_serve'
expected={'prompt_tokens_total':0,'generation_tokens_total':0,'cached_tokens_total':0,'cache_accounted_prompt_tokens_total':0};proof=[]
def start():
    p=subprocess.Popen([str(binary),'serve',str(E/'zig/tests/server/fixtures'),'--name','fake-model','--port','0','--max-tokens','64','--parallel','4'],stdout=subprocess.PIPE,stderr=(O/'fake-server-stderr.log').open('ab'),env=dict(os.environ,TENSORFOLD_NO_LIVE='1',TF_FAKE_CONTEXT='1024'),start_new_session=True)
    sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ);buf=b'';end=time.monotonic()+8
    while time.monotonic()<end:
        if not sel.select(.1):continue
        b=os.read(p.stdout.fileno(),4096)
        if not b:raise RuntimeError('native server exited before PORT')
        buf+=b
        m=re.search(rb'(?:^|\n)PORT (\d+)\r?\n',buf)
        if m:sel.close();return p,int(m.group(1))
    p.kill();p.wait();raise RuntimeError('no PORT within8s')
def get(port,path):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=5);c.request('GET',path);r=c.getresponse();b=r.read();assert r.status==200;c.close();return b
def metrics(port):
    return {k:float(v) for k,v in re.findall(r'^tensorfold:([a-z_]+) ([0-9.eE+-]+)$',get(port,'/metrics').decode(),re.M)}
def request(port,script='plain',stream=False,anthropic=False,cancel=False):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=8)
    body={'model':'fake-model','messages':[{'role':'user','content':'Hi @script='+script}],'max_tokens':32,'stream':stream}
    if stream and not anthropic:body['stream_options']={'include_usage':True}
    c.request('POST','/v1/messages' if anthropic else '/v1/chat/completions',json.dumps(body),{'Content-Type':'application/json'});r=c.getresponse();assert r.status==200,r.status
    if cancel:
        r.fp.readline();c.close();return {'cancelled':True}
    b=r.read();c.close()
    if stream:
        frames=[json.loads(x[6:]) for x in b.decode().splitlines() if x.startswith('data: ') and x!='data: [DONE]'];u=next(x['usage'] for x in reversed(frames) if x.get('usage'))
    else:u=json.loads(b)['usage']
    if anthropic:p=u['input_tokens']+u.get('cache_read_input_tokens',0);cached=u.get('cache_read_input_tokens',0);g=u['output_tokens']
    else:p=u['prompt_tokens'];cached=u.get('prompt_tokens_details',{}).get('cached_tokens',0);g=u['completion_tokens']
    return {'prompt':p,'cached':cached,'generation':g,'body_sha256':hashlib.sha256(b).hexdigest(),'script':script,'stream':stream,'anthropic':anthropic}
def reconcile(port,items):
    for r in items:
        expected['prompt_tokens_total']+=r['prompt'];expected['cached_tokens_total']+=r['cached'];expected['generation_tokens_total']+=r['generation'];expected['cache_accounted_prompt_tokens_total']+=r['prompt']
    end=time.monotonic()+3
    while True:
        m=metrics(port)
        if all(m[k]==v for k,v in expected.items()):break
        assert time.monotonic()<end,(m,expected);time.sleep(.02)
    assert m['uncached_prompt_tokens_total']==m['cache_accounted_prompt_tokens_total']-m['cached_tokens_total'];proof.append({'usage':items,'metrics':m})
p=None
try:
    p,port=start();zero=metrics(port);epoch=zero['counter_epoch_milliseconds'];assert zero['cache_accounting_schema']==1 and all(zero[k]==0 for k in expected)
    reconcile(port,[request(port)]);reconcile(port,[request(port,'think')]);reconcile(port,[request(port,'think',True)]);reconcile(port,[request(port,'think',anthropic=True)])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:rs=list(pool.map(lambda _:request(port,'think'),range(4)))
    reconcile(port,rs)
    before=metrics(port);request(port,'slow',True,cancel=True);time.sleep(.3);after=metrics(port)
    assert after['counter_epoch_milliseconds']==epoch and after['cached_tokens_total']<=after['cache_accounted_prompt_tokens_total']<=after['prompt_tokens_total'];proof.append({'cancel_before':before,'cancel_after':after})
    p.terminate();p.wait(timeout=5);p=None;time.sleep(.01);p,port=start();fresh=metrics(port);assert fresh['counter_epoch_milliseconds']!=epoch and all(fresh[k]==0 for k in expected);proof.append({'fresh_registry':fresh})
    (O/'native-cache-http.json').write_text(json.dumps({'passed':True,'scripted_engine':True,'real_model_inference':False,'normal_requests':8,'cancel_requests':1,'checks':proof},indent=2));print(json.dumps({'passed':True,'normal_requests':8,'cancel_requests':1,'new_epoch':fresh['counter_epoch_milliseconds']}))
finally:
    if p is not None and p.poll() is None:
        p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait()
