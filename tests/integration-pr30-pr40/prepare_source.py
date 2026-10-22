"""Materialize the pinned engine from existing Git objects and strictly apply this recipe.

No fetch, build, model, GPU, SSH or service operation. Output must not already exist.
Windows-incompatible golden filenames are recorded rather than silently renamed.
"""
from pathlib import Path
import argparse,subprocess,io,json,hashlib,os
PIN='629c524a0ea57512a5342abb498d1b7c25353343'
ap=argparse.ArgumentParser();ap.add_argument('--engine-repo',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
recipe=Path(__file__).resolve().parents[2];a.out.mkdir(parents=True,exist_ok=False)
def git(*args):return subprocess.check_output(['git','-C',str(a.engine_repo),*args])
entries=[];omitted=[]
for line in git('ls-tree','-r','-z',PIN).split(b'\0'):
 if not line:continue
 meta,name=line.split(b'\t',1);mode,kind,oid=meta.decode().split();name=name.decode()
 if os.name=='nt' and any(c in name for c in '<>:"|?*'):
  omitted.append({'path':name,'blob':oid,'sha256':hashlib.sha256(git('cat-file','blob',oid)).hexdigest()});continue
 assert kind=='blob' and mode!='120000',(mode,name)
 entries.append((name,oid,mode))
p=subprocess.run(['git','-C',str(a.engine_repo),'cat-file','--batch'],input=('\n'.join(oid for _,oid,_ in entries)+'\n').encode(),capture_output=True,check=True);stream=io.BytesIO(p.stdout)
for name,oid,mode in entries:
 h=stream.readline().decode().split();assert h[0]==oid
 raw=stream.read(int(h[2]));assert stream.read(1)==b'\n'
 dest=a.out/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(raw)
 if os.name!='nt':dest.chmod(0o755 if mode=='100755' else 0o644)
patches=[]
for patch in sorted((recipe/'zig/patches').glob('*.patch')):
 subprocess.run(['git','-c','core.autocrlf=false','apply','--check',str(patch)],cwd=a.out,check=True)
 subprocess.run(['git','-c','core.autocrlf=false','apply',str(patch)],cwd=a.out,check=True)
 patches.append({'file':patch.name,'sha256':hashlib.sha256(patch.read_bytes()).hexdigest()})
receipt={'engine':PIN,'patches':patches,'windows_omitted_goldens':omitted,'production_tested':False}
(a.out/'integration-source.json').write_text(json.dumps(receipt,indent=2),encoding='utf8')
manifest=''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(a.out).as_posix()+'\n' for p in sorted(a.out.rglob('*')) if p.is_file())
(a.out/'SOURCE_SHA256SUMS').write_text(manifest,encoding='utf8',newline='\n')
print(json.dumps({'patches_applied':len(patches),'omitted_goldens':len(omitted),'source_manifest_sha256':hashlib.sha256(manifest.encode()).hexdigest()}))
