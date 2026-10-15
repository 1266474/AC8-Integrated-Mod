"""Write LauncherVersion.cs (title, company and version of AC8 Integrated.exe) from the repository's version.json."""
from pathlib import Path
import json,re,sys
version=json.loads((Path(__file__).resolve().parents[2]/'version.json').read_text(encoding='utf-8'))['version']
number='.'.join(re.match(r'^(\d+)\.(\d+)\.(\d+)',version).groups())
Path(sys.argv[1]).write_text('\n'.join([
 'using System.Reflection;',
 '[assembly: AssemblyTitle("AC8 Integrated")]',
 '[assembly: AssemblyDescription("AC8 Integrated player tool")]',
 '[assembly: AssemblyCompany("CreeperUX")]',
 '[assembly: AssemblyProduct("AC8 Integrated")]',
 f'[assembly: AssemblyVersion("{number}.0")]',
 f'[assembly: AssemblyFileVersion("{number}")]',
 f'[assembly: AssemblyInformationalVersion("{version}")]',''
]),encoding='utf-8')
