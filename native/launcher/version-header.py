"""Write launcher-version.h (version resource of AC8 Integrated.exe) from the repository's version.json."""
from pathlib import Path
import json,re,sys
version=json.loads((Path(__file__).resolve().parents[2]/'version.json').read_text(encoding='utf-8'))['version']
numbers=[int(x) for x in re.match(r'^(\d+)\.(\d+)\.(\d+)',version).groups()]+[0]
Path(sys.argv[1]).write_text(f'#define AC8_VERSION_NUM {",".join(map(str,numbers))}\n#define AC8_VERSION_STR "{version}"\n',encoding='ascii')
