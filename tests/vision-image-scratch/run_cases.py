"""CPU-only Linux ARM64 comparison; all raw inputs stay in private staging."""
import datetime as dt,json,pathlib,subprocess,time,statistics,shutil,os
R=pathlib.Path(os.environ.get('VISION_AB_WORK','/work/offline'));R.mkdir(exist_ok=True);INPUT=pathlib.Path(os.environ.get('VISION_AB_INPUT','/input'))
def utc():return dt.datetime.now(dt.timezone.utc).isoformat()
def case(mode,n,lanes,group,fail=0):
 name=f'{group}-n{n}-l{lanes}-{mode}-f{fail}';dest=R/name;dest.mkdir(exist_ok=False)
 prior=pathlib.Path('/prior-offline')/name
 if (prior/'result.json').exists():
  result=json.loads((prior/'result.json').read_text());assert result['passed']
  shutil.copytree(prior,dest,dirs_exist_ok=True)
  print(json.dumps({'case':name,'reused_completed_measurement':True}),flush=True)
  return result
 args=[os.environ.get('VISION_AB_BINARY','/work/vision_ab'),mode,str(n),str(lanes),str(INPUT/(group+'.lst')),str(fail)]
 start=time.monotonic();samples=[]
 with (dest/'stdout.log').open('xb') as out,(dest/'stderr.log').open('xb') as err:
  p=subprocess.Popen(args,cwd=INPUT,stdin=subprocess.DEVNULL,stdout=out,stderr=err)
  while p.poll() is None:
   try:
    values={}
    for line in pathlib.Path(f'/proc/{p.pid}/smaps_rollup').read_text().splitlines():
     parts=line.split()
     if parts[0] in ('Rss:','Pss:','Anonymous:','Private_Dirty:','Swap:'):values[parts[0][:-1]]=int(parts[1])*1024
    samples.append({'utc':utc(),'elapsed':time.monotonic()-start,**values})
   except FileNotFoundError:pass
   if time.monotonic()-start>30:p.terminate();raise RuntimeError('case deadline')
   time.sleep(.02)
  rc=p.wait(timeout=3)
 records=[]
 for line in (dest/'stderr.log').read_text(errors='replace').splitlines():
  if ' ' not in line:continue
  k,v=line.split(' ',1)
  if k in ('LANE','IMAGE','BOUNDARY','FAIL','SUMMARY','PARITY','ERROR_PARITY'):records.append({'kind':k,**json.loads(v)})
 lanes_data=[x for x in records if x['kind']=='LANE'];summary=[x for x in records if x['kind']=='SUMMARY']
 assert len(summary)==1
 assert rc==(2 if fail else 0),(name,rc)
 assert all(x['live']==0 for x in lanes_data)
 if fail:assert all(x['failed'] or x['denied'] for x in lanes_data)
 else:assert summary[0].get('equal',True) and not summary[0].get('failed',False)
 (dest/'resources.jsonl').write_text(''.join(json.dumps(s)+'\n' for s in samples))
 result={'case':name,'utc':utc(),'rc':rc,'passed':True,'seconds':time.monotonic()-start,'pid':p.pid,'records':records,
  'peak':{k:max((s.get(k,0) for s in samples),default=0) for k in ('Rss','Pss','Anonymous','Swap')}}
 (dest/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='records'}),flush=True)
 return result
results=[];began=time.monotonic()
for group,n,l in [('full',4,1),('full',8,1),('small',7,1),('full',8,2),('jpeg',1,1)]:
 pair=[case(m,n,l,group) for m in ('baseline','scratch')];results+=pair
 def outputs(r):return sorted((x['lane'],x['image'],x['tokens'],x['payload_bytes'],x['sha256']) for x in r['records'] if x['kind']=='IMAGE')
 assert outputs(pair[0])==outputs(pair[1]),'payload mismatch'
for group,n,mode in [('all',58,'parity'),('jpeg',1,'parity'),('errors',2,'errors')]:results.append(case(mode,n,1,group))
# Exercise every allocating call attempted in a successful one-image path, including
# caller-owned final payload. Failure is sticky; each run must unwind all blocks.
for mode in ('baseline','scratch'):
 probe=case(mode,1,1,'full');results.append(probe)
 allocations=next(x['allocs'] for x in probe['records'] if x['kind']=='LANE')
 assert allocations<=40,allocations
 for fail in range(1,allocations+1):
  if time.monotonic()-began>180:raise RuntimeError('offline batch deadline')
  results.append(case(mode,1,1,'full',fail))
(R/'summary.json').write_text(json.dumps({'utc':utc(),'passed':True,'cases':len(results),'seconds':time.monotonic()-began,'names':[r['case'] for r in results]},indent=2))
