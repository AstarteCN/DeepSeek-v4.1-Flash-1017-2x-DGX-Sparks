"""Offline profile checks: no model, network, container or private configuration."""
from pathlib import Path
import os,shlex,shutil,subprocess,json
EXPECTED_MODEL='878f5689915bcb44d985125e9a8cd4b78874e546'
EXPECTED_ENGRAM='1bae0e1088993b9b82de08f59de5be5a34e42170'
profile=Path(__file__).with_name('candidate.env.example').resolve()
if os.name=='nt':
    git=Path(shutil.which('git') or '')
    bash=git.parent.parent/'bin/bash.exe'
    if not bash.is_file():raise SystemExit('Git Bash required; never substitute WSL')
else:
    bash=shutil.which('bash')
    if not bash:raise SystemExit('Bash required')
script='set -e; source '+shlex.quote(profile.as_posix())+'; printf "%s %s %s" "$MODEL_REVISION" "$ENGRAM_REVISION" "$HF_HUB_OFFLINE"'
base=os.environ.copy()
for k in ['VERIFIED_STABLE_MODEL_REVISION','VERIFIED_STABLE_ENGRAM_REVISION']:base.pop(k,None)
cases=[('missing',{},False),('recorded',{'VERIFIED_STABLE_MODEL_REVISION':EXPECTED_MODEL,'VERIFIED_STABLE_ENGRAM_REVISION':EXPECTED_ENGRAM},True),('upstream-new-is-not-stable',{'VERIFIED_STABLE_MODEL_REVISION':'45ee5d0fd106c94a3d77f721e09cbb2f50e5a16b','VERIFIED_STABLE_ENGRAM_REVISION':EXPECTED_ENGRAM},False),('engram-mismatch',{'VERIFIED_STABLE_MODEL_REVISION':EXPECTED_MODEL,'VERIFIED_STABLE_ENGRAM_REVISION':'0'*40},False)]
out=[]
for name,extra,want in cases:
    p=subprocess.run([str(bash),'-c',script],env=dict(base,**extra),capture_output=True,text=True,encoding='utf8',timeout=10)
    passed=(p.returncode==0)==want
    if want:passed=passed and p.stdout==EXPECTED_MODEL+' '+EXPECTED_ENGRAM+' 1'
    out.append({'case':name,'passed':passed,'exit':p.returncode})
print(json.dumps(out));raise SystemExit(int(not all(x['passed'] for x in out)))
