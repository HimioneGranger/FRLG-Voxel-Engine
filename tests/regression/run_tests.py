"""Run portable engine regression tests with an installed LOVE 11.5 runtime.

Example: python run_tests.py --repo /path/to/repo --love /path/to/love
No ROM, assets, game installation or network is needed for these tests.
"""
from pathlib import Path
import argparse,json,os,subprocess
p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--love',required=True);p.add_argument('--output',required=True);a=p.parse_args()
R=Path(a.repo).resolve();H=Path(__file__).resolve().parent;O=Path(a.output).resolve()
O.mkdir(parents=True,exist_ok=False)
env=dict(os.environ,FRLG_ENGINE_ROOT=(R/'FRLG_VOXEL').as_posix())
for folder,var in [('Roaming','APPDATA'),('Local','LOCALAPPDATA')]:
 d=O/'isolated-profile'/folder;d.mkdir(parents=True);env[var]=str(d)
kwargs={}
if os.name=='nt':
 si=subprocess.STARTUPINFO();si.dwFlags|=subprocess.STARTF_USESHOWWINDOW;si.wShowWindow=0
 kwargs={'startupinfo':si,'creationflags':subprocess.CREATE_NO_WINDOW}
results={}
for name,marker in [('existing','EXISTING_PUBLIC_TESTS_PASS'),('preparation','PREPARATION MODE TESTS PASS'),('tree-cache','VOXEL_CACHE_TESTS_PASS')]:
 r=subprocess.run([str(Path(a.love).resolve()),str(H/name)],cwd=R,env=env,capture_output=True,text=True,timeout=90,**kwargs)
 text=r.stdout+r.stderr;(O/(name+'.log')).write_text(text,encoding='utf-8')
 print(text,flush=True);results[name]={'exit':r.returncode,'pass':r.returncode==0 and marker in text}
 assert results[name]['pass'],name+' failed'
(O/'results.json').write_text(json.dumps({'status':'PASS','results':results},indent=2)+'\n',encoding='utf-8')
print('ALL_PORTABLE_TESTS_PASS')
