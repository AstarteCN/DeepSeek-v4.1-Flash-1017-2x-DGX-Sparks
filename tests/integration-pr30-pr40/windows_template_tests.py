"""Bounded host adapter: real candidate template code, POSIX clock function unavailable.

Only strftimeNow is refused in a disposable copy. Selected tests never call it.
This is not a replacement for unmodified Linux template/server/golden tests.
"""
from pathlib import Path
import argparse,shutil,subprocess,json,time,hashlib,os
try:
 import psutil
 psutil.Process().cpu_affinity(psutil.Process().cpu_affinity()[:2])
except ImportError:
 pass
ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--zig',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
a.out.mkdir(parents=True,exist_ok=False);root=a.out/'template';shutil.copytree(a.source/'zig/src/core/template',root)
p=root/'methods.zig';old=p.read_text(encoding='utf8');begin=old.index('fn strftimeNow(');end=old.index('\n}',begin)+2
new=old[:begin]+'''fn strftimeNow(rt: *Rt, fmt: []const u8) Error![]const u8 {
    _ = fmt;
    return rt.fail("POSIX clock unavailable in Windows test adapter", .{});
}'''+old[end:];p.write_text(new,encoding='utf8',newline='\n')
here=Path(__file__).resolve().parent;recipe=here.parents[1]
shutil.copyfile(recipe/'tests/list-prefix-concat/list_concat_tests.zig',root/'integration_list_tests.zig')
with (root/'template.zig').open('a',encoding='utf8') as f:f.write('\ntest { _ = @import("integration_list_tests.zig"); }\n')
result={'adapter':{'production_methods_sha256':hashlib.sha256(old.encode()).hexdigest(),'host_methods_sha256':hashlib.sha256(new.encode()).hexdigest(),'change':'only strftimeNow is refused, not exercised by selected tests'},'tests':[]}
for label in ['immutable','a render keeps only','appending to a long string','engine context','numeric members','syntax and unknown']:
 start=time.monotonic();q=subprocess.run([str(a.zig.resolve()),'test','-lc','-O','ReleaseSafe',str((root/'template.zig').resolve()),'--test-filter',label],capture_output=True,timeout=150)
 item={'filter':label,'rc':q.returncode,'seconds':time.monotonic()-start,'stdout':q.stdout.decode(errors='replace'),'stderr':q.stderr.decode(errors='replace')};result['tests'].append(item)
 (a.out/'results.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps({'filter':label,'rc':q.returncode,'tail':item['stderr'][-700:]}),flush=True)
 if q.returncode:break
raise SystemExit(int(any(t['rc'] for t in result['tests'])))
