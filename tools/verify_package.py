"""Verify the downloaded source tree; optionally compile Lua with LuaJIT."""
from pathlib import Path
import argparse,hashlib,json,re,shutil,subprocess

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--lua',help='Optional LuaJIT executable for syntax checks')
    args=ap.parse_args()
    root=Path(__file__).resolve().parents[1]
    manifest=json.loads((root/'package-manifest.json').read_text())
    for item in manifest['files']:
        p=root/item['path']
        assert p.is_file(),f"Missing {item['path']}"
        assert hashlib.sha256(p.read_bytes()).hexdigest()==item['sha256'],f"Changed {item['path']}"
    forbidden={'.gba','.gb','.gbc','.rom','.sav','.srm','.apk','.love','.pem','.key','.pfx','.p12','.jks','.keystore'}
    secret=re.compile(rb'(?:github_pat_[A-Za-z0-9_]{30,}|ghp_[A-Za-z0-9]{30,}|-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----)')
    for p in root.rglob('*'):
        if not p.is_file() or '.git' in p.parts:continue
        assert p.suffix.lower() not in forbidden,f"Forbidden game/private input: {p.relative_to(root)}"
        if p.suffix in {'.lua','.json','.md','.txt','.py'}:
            assert not secret.search(p.read_bytes()),f"Credential pattern: {p.relative_to(root)}"
    lua=args.lua or shutil.which('luajit')
    count=0
    if lua:
        for p in (root/'FRLG_VOXEL').rglob('*.lua'):
            # Pass path as an argument, never interpolate source into shell code.
            subprocess.run([lua,'-e','assert(loadfile(io.read("*l")))'],input=str(p)+'\n',
                           text=True,check=True,capture_output=True)
            count+=1
    print(json.dumps({'filesVerified':len(manifest['files']),'luaSyntaxChecked':count,
                      'luaAvailable':bool(lua),'scope':'Integrity and syntax; no live host or headset acceptance'}))

if __name__=='__main__':main()
