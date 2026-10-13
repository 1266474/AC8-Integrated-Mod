$ErrorActionPreference='Stop'
# Extra UE4SS mods (2.4.3): package\ue4ss-mods folders are detected, validated and deployed with this package's UE4SS.
$repo=Split-Path $PSScriptRoot -Parent;$template=Join-Path $repo 'package-template'
. (Join-Path $template 'Feature-Settings.ps1')
$root=Join-Path $repo ('native/test-runtime/extramods-'+[guid]::NewGuid().ToString('N'));$package=Join-Path $root 'package';$extra=Join-Path $package 'ue4ss-mods'
New-Item -ItemType Directory -Path $extra -Force | Out-Null
function New-Mod([string]$Name,[string[]]$Files){foreach($f in $Files){$p=Join-Path (Join-Path $extra $Name) $f;New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null;Set-Content -LiteralPath $p -Value "-- $Name" -Encoding ASCII}}
if(@(Get-AC8ExtraMods (Join-Path $root 'no-package')).Count){throw 'Missing folder must yield no mods'}
Set-Content -LiteralPath (Join-Path $extra 'README.txt') -Value 'readme' -Encoding ASCII
New-Mod 'LuaMod' @('Scripts/main.lua','Scripts/helper.lua')
New-Mod 'CppMod' @('dlls/main.dll')
New-Mod 'Both.Mod-2' @('Scripts/main.lua','dlls/main.dll')
New-Mod '_Disabled' @('Scripts/main.lua')
New-Mod 'NotAMod' @('readme.txt')
New-Mod 'AC8MouseAim' @('Scripts/main.lua')
New-Mod 'shared' @('Scripts/main.lua')
New-Mod 'Bad Name' @('Scripts/main.lua')
$outside=Join-Path $root 'outside';New-Item -ItemType Directory -Path (Join-Path $outside 'Scripts') -Force | Out-Null;Set-Content -LiteralPath (Join-Path $outside 'Scripts/main.lua') -Value '--' -Encoding ASCII
New-Item -ItemType Directory -Path (Join-Path $extra 'Linked') | Out-Null
New-Item -ItemType Junction -Path (Join-Path $extra 'Linked/Scripts') -Target (Join-Path $outside 'Scripts') | Out-Null
$found=@(Get-AC8ExtraMods $package)
$byName=@{};foreach($m in $found){$byName[$m.Name]=$m}
if($found.Count -ne 9){throw "Expected 9 folders, got $($found.Count)"}
foreach($n in 'LuaMod','CppMod','Both.Mod-2'){if($byName[$n].Problem){throw "$n rejected: $($byName[$n].Problem)"}}
if($byName['LuaMod'].Kind -ne 'Lua' -or $byName['CppMod'].Kind -ne 'C++' -or $byName['Both.Mod-2'].Kind -ne 'Lua+C++'){throw 'Kind detection wrong'}
foreach($n in '_Disabled','NotAMod','AC8MouseAim','shared','Bad Name','Linked'){if(!$byName[$n].Problem){throw "$n should be skipped"}}
if($byName['Linked'].Problem -notlike '*链接*'){throw 'Junction not reported as a link'}
# deployment: own mods first, then usable extras, shared library staged, skipped ones absent
$selection=[pscustomobject]@{MissileMode='full';MissileEnhancement=$true;ExpectedFields=375}
$dest=Join-Path $root 'stage';New-Item -ItemType Directory -Path $dest | Out-Null;Set-Content -LiteralPath (Join-Path $dest 'AC8SourceInit-owner.txt') -Value 'owner'
Install-SelectedUE4SS (Join-Path $template 'payload/Game/Binaries/Win64/ue4ss') $dest $selection $found
$lines=@(Get-Content -LiteralPath (Join-Path $dest 'Mods/mods.txt'))
$expected=@('AC8SourceInit : 1','AC8MouseAim : 1','Both.Mod-2 : 1','CppMod : 1','LuaMod : 1')
if(($lines -join '|') -ne ($expected -join '|')){throw "mods.txt: $($lines -join '|')"}
foreach($p in 'Mods/LuaMod/Scripts/main.lua','Mods/LuaMod/Scripts/helper.lua','Mods/CppMod/dlls/main.dll','Mods/Both.Mod-2/dlls/main.dll','Mods/shared/UEHelpers/UEHelpers.lua','Mods/AC8MouseAim/Scripts/main.lua'){
 if(!(Test-Path -LiteralPath (Join-Path $dest $p))){throw "Missing staged $p"}}
foreach($p in 'Mods/_Disabled','Mods/NotAMod','Mods/Bad Name','Mods/Linked'){if(Test-Path -LiteralPath (Join-Path $dest $p)){throw "Skipped mod staged: $p"}}
if((Get-Content -LiteralPath (Join-Path $dest 'Mods/AC8MouseAim/Scripts/main.lua') -Raw) -like '-- AC8MouseAim*'){throw 'Extra folder overwrote the bundled AC8MouseAim'}
# without extras the module list is unchanged from 2.4.2
$plain=Join-Path $root 'plain';New-Item -ItemType Directory -Path $plain | Out-Null;Set-Content -LiteralPath (Join-Path $plain 'AC8SourceInit-owner.txt') -Value 'owner'
Install-SelectedUE4SS (Join-Path $template 'payload/Game/Binaries/Win64/ue4ss') $plain $selection
if((@(Get-Content -LiteralPath (Join-Path $plain 'Mods/mods.txt')) -join '|') -ne 'AC8SourceInit : 1|AC8MouseAim : 1'){throw 'Module list changed without extras'}
# the shipped folder holds only the README
if(@(Get-AC8ExtraMods $template).Count){throw 'Package template ships extra mods'}
[IO.Directory]::Delete((Join-Path $extra 'Linked/Scripts'),$false)   # the junction only, never its target
if(!(Test-Path -LiteralPath (Join-Path $outside 'Scripts/main.lua'))){throw 'Junction target was touched'}
Remove-Item -LiteralPath $root -Recurse -Force
Write-Host 'PASS extra UE4SS mods: Lua/C++ detected, disabled/invalid/reserved/linked folders skipped, deployed after own mods with the shared library, unchanged without extras'
