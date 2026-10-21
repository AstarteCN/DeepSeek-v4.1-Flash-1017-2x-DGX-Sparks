"""Generate only synthetic inputs from the repository's existing fixtures."""
from pathlib import Path
import hashlib,importlib.util,json,shutil
D=Path(__file__).resolve().parent;R=D.parents[1];F=D/'fixtures'
spec=importlib.util.spec_from_file_location('hf_fixtures',R/'tests/hf-scratch/make_fixtures.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
assert not F.exists();m.OUT=F;m.main()
manifest=[x for x in json.loads((F/'manifest.json').read_text()) if x['default_run']]
for folder in [R/'tests/list-prefix-concat/fixtures',D/'additional-fixtures']:
 for x in json.loads((folder/('manifest-additions.json' if folder.name=='fixtures' else 'manifest.json')).read_text()):
  shutil.copyfile(folder/x['file'],F/x['file']);manifest.append(x)
assert len(manifest)==38
for x in manifest:assert hashlib.sha256((F/x['file']).read_bytes()).hexdigest()==x['sha256']
(F/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'pairs':len(manifest),'optional_8192_run':False}))
