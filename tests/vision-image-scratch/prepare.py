"""Build an offline adapter from the actual patched source; no network/model."""
import argparse,hashlib,json,shutil,struct,zlib
from pathlib import Path
from PIL import Image,ImageDraw
ap=argparse.ArgumentParser();ap.add_argument('--source',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);args=ap.parse_args()
here=Path(__file__).resolve().parent;out=args.out;out.mkdir(parents=True,exist_ok=False)
family=args.source/'zig/src/families/dsv41';text=(family/'vision.zig').read_text()
def function(name):
 start=text.index('    fn '+name+'(');end=text.index('\n    }',start)+6
 return '\n'.join(line[4:] if line.startswith('    ') else line for line in text[start:end].splitlines())+'\n'
original=function('prepareScratch').replace('fn prepareScratch(','fn prepareFn(')
wrapper=function('prepareFn').replace('fn prepareFn(','fn prepareCandidate(')
assert 'std.heap.page_allocator' in wrapper
wrapper=wrapper.replace('std.heap.page_allocator','@as(*Vision, @ptrCast(@alignCast(ctx))).tracking.allocator()')
vision='const Vision=struct {\n cfg:picture.Config=.{},tracking:*Tracking,lane:usize,image:usize=0,pil:?*pil.Pil=null,\n'+function('decode')+'};\n'
body=(here/'harness-prefix.zig').read_text()+vision+original+wrapper+function('prepareScratch')+(here/'harness-suffix.zig').read_text()
(out/'vision_ab.zig').write_text(body,encoding='utf8',newline='\n')
for name in ('picture.zig','pil.zig'):shutil.copy2(family/name,out/name)
shutil.copy2(here/'run_cases.py',out/'run_cases.py');(out/'fixtures').mkdir()
groups={'full':[],'small':[],'all':[]}
for i in range(58):
 group='full' if i<51 else 'small';w,h=(1920,1080) if group=='full' else (854,480)
 image=Image.new('RGB',(w,h),(i*7%256,i*19%256,i*31%256));draw=ImageDraw.Draw(image)
 for j in range(24):
  x=j*w//24;draw.line((x,0,w-x,h-1),fill=((i+j*11)%256,j*9%256,(j*17+i)%256),width=3)
 name=f'fixtures/synthetic-{i:02}.png';image.save(out/name);groups[group].append(name);groups['all'].append(name)
for group,names in groups.items():(out/(group+'.lst')).write_text('\n'.join(names)+'\n')
Image.new('RGB',(320,240),(31,77,123)).save(out/'fixtures/synthetic.jpg');(out/'jpeg.lst').write_text('fixtures/synthetic.jpg\n')
(out/'fixtures/invalid.bin').write_bytes(b'invalid synthetic image data')
head=struct.pack('>IIBBBBB',20000,20000,8,2,0,0,0)
(out/'fixtures/oversized.png').write_bytes(b'\x89PNG\r\n\x1a\n'+struct.pack('>I',len(head))+b'IHDR'+head+struct.pack('>I',zlib.crc32(b'IHDR'+head))+b'\0\0\0\0IEND\xaeB`\x82')
(out/'errors.lst').write_text('fixtures/invalid.bin\nfixtures/oversized.png\n')
(out/'source-receipt.json').write_text(json.dumps({'vision_sha256':hashlib.sha256((family/'vision.zig').read_bytes()).hexdigest(),'harness_sha256':hashlib.sha256((out/'vision_ab.zig').read_bytes()).hexdigest(),'contains_user_input':False},indent=2))
print('Prepared synthetic CPU-only adapter. No compilation, network or model launch performed.')
