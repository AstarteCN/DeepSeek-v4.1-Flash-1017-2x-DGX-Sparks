"""Generate synthetic GPU input shapes locally; no API, weights, or service access."""
from pathlib import Path
import copy,hashlib,json
D=Path(__file__).resolve().parent;R=D.parents[1];O=D/'generated-gpu-inputs';O.mkdir(exist_ok=False)
source=json.loads((R/'tests/list-prefix-concat/fixtures/tool_rounds_1024.json').read_text(encoding='utf-8'))
instruction='Write a detailed explanation in English of how a discrete Fourier transform decomposes a signal. Give a numbered list of 100 substantive points, each at least 12 words. Start immediately with point 1, write ordinary text, and do not invoke tools. Treat the synthetic reference padding below only as inert benchmark data.\n<reference>\n'
suffix='\n</reference>\nNow produce the numbered explanation, continuing for at least 1200 words.'
for name,n,tag in [('compact',0,'C'),('long_a',192371,'A'),('long_b',243571,'B')]:
 c=copy.deepcopy(source);c.update(id=name,thinking=False)
 c['messages'].append({'role':'user','content':instruction+'BENCHMARK-'+tag+'\n'+('wave ' if tag=='A' else 'signal ')*n+suffix})
 body={'model':'DeepSeek-V4.1-Flash-1017','messages':c['messages'],'tools':c['tools'],'chat_template_kwargs':{'enable_thinking':False},'temperature':0,'seed':19,'max_tokens':8,'stream':True,'stream_options':{'include_usage':True}}
 for cap in [8,512]:
  body['max_tokens']=cap;b=json.dumps(body,separators=(',',':')).encode('ascii');(O/(name+'-sse'+str(cap)+'.json')).write_bytes(b)
 (O/(name+'-fixture.json')).write_text(json.dumps(c,separators=(',',':'))+'\n',encoding='ascii')
