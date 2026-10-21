from pathlib import Path
import hashlib,json,random
from jinja2.sandbox import ImmutableSandboxedEnvironment
D=Path(__file__).resolve().parent;F=D/'fixtures'
manifest=json.loads((F/'manifest.json').read_text())
tool=json.loads((D/'merge-fixture.json').read_text(encoding='utf-8'))['tools'][0]
env=ImmutableSandboxedEnvironment(extensions=['jinja2.ext.loopcontrols'])
def raised(x):raise ValueError(x)
env.globals['raise_exception']=raised
templates=[env.from_string((D/n).read_text(encoding='utf-8')) for n in ['baseline-chat-template.jinja','candidate-chat-template.jinja']]
cases=[json.loads((F/x['file']).read_text(encoding='utf-8')) for x in manifest if not x.get('memory_probe') and x['id']!='same_instance_error_recovery']
rng=random.Random(130013)
roles=['user','tool','assistant','system','latest_reminder']
for i in range(256):
 msgs=[]
 for j in range(rng.randrange(0,25)):
  role=rng.choice(roles);m={'role':role,'content':rng.choice(['文字🧪','',None,{'k':[1,'值']},['数组',2]])}
  if role=='assistant':m.update(content='答复',reasoning_content='思考');m['tool_calls']=[{'id':'a','function':{'name':'测量','arguments':{'值':j}}}] if rng.randrange(2) else []
  if role=='tool':m['tool_call_id']=rng.choice(['a','b',''])
  msgs.append(m)
 cases.append({'id':f'fuzz_{i}','messages':msgs,'thinking':bool(rng.randrange(2)),'tools':[tool] if rng.randrange(2) else [],'effort':rng.choice(['low','high','max','bad'])})
results=[]
for case in cases:
 for generation in [False,True]:
  outcomes=[]
  for t in templates:
   try:value=t.render(messages=case['messages'],tools=case.get('tools',[]),enable_thinking=case.get('thinking',False),reasoning_effort=case.get('effort','high'),add_generation_prompt=generation);outcomes.append(('ok',value))
   except Exception as e:outcomes.append((type(e).__name__,str(e)))
  assert outcomes[0]==outcomes[1],case['id']
  results.append({'id':case['id'],'generation':generation,'kind':outcomes[0][0],'sha256':hashlib.sha256(outcomes[0][1].encode()).hexdigest()})

assert len(results)==560
print(json.dumps({'pairs':len(results),'seed':130013,'exact':True}))
