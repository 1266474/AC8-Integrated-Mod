$ErrorActionPreference='Stop'
# AC8 Integrated.exe (native\launcher, 2.5.0): a Windows-subsystem program without a console, with the AC8 icon, version
# information and an asInvoker manifest, no build-machine paths; it starts Host.ps1 -Action Gui at an install root and
# Launcher-GUI.ps1 in a package folder. Resolution is checked with --dry-run (nothing is started). Needs
# native\launcher\build.cmd first.
$repo=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $repo 'native\build\AC8 Integrated.exe'
if(!(Test-Path -LiteralPath $exe)){throw 'Build native\launcher\build.cmd first.'}
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
$bytes=[IO.File]::ReadAllBytes($exe);$pe=[BitConverter]::ToInt32($bytes,0x3c)
Assert-True ([BitConverter]::ToUInt16($bytes,$pe+24+68) -eq 2) 'must be a Windows (GUI) subsystem program, not a console program'
$text=[Text.Encoding]::ASCII.GetString($bytes)
Assert-True ($text -match 'requestedExecutionLevel\s+level="asInvoker"') 'must not ask for administrator rights'
Assert-True ($text -notmatch '(?i)[a-z]:[\\/]+users[\\/]') 'build-machine path in the program'
$version=(Get-Content -LiteralPath (Join-Path $repo 'version.json') -Raw | ConvertFrom-Json).version
$info=(Get-Item -LiteralPath $exe).VersionInfo
Assert-True ($info.ProductName -eq 'AC8 Integrated' -and $info.FileVersion -eq $version -and $info.CompanyName -eq 'CreeperUX') ('version information: '+$info.FileVersion)
Add-Type -AssemblyName System.Drawing
$icon=[Drawing.Icon]::ExtractAssociatedIcon($exe);Assert-True ($icon.Width -ge 32) 'embedded icon';$icon.Dispose()
$fixture=Join-Path $repo ('native/test-runtime/launcher-'+[guid]::NewGuid().ToString('N'))
$powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
foreach($case in @(
 @{Name='install root';Files=@('Host.ps1','Launcher-GUI.ps1');Code=0;Expect=('"'+$powershell+'" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}\Host.ps1" -Action Gui')},
 @{Name='package folder';Files=@('Launcher-GUI.ps1');Code=0;Expect=('"'+$powershell+'" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}\Launcher-GUI.ps1"')},
 @{Name='nothing to start';Files=@();Code=2;Expect='error: *'}
)){
 $dir=Join-Path $fixture (($case.Name -replace ' ','-')+' with space');New-Item -ItemType Directory -Path $dir -Force | Out-Null
 Copy-Item -LiteralPath $exe -Destination $dir;foreach($file in $case.Files){[IO.File]::WriteAllText((Join-Path $dir $file),'')}
 $out=Join-Path $fixture (($case.Name -replace ' ','-')+'.txt')
 $process=Start-Process -FilePath (Join-Path $dir 'AC8 Integrated.exe') -ArgumentList @('--dry-run',('"'+$out+'"')) -Wait -PassThru
 $result=[IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)
 Assert-True ($process.ExitCode -eq $case.Code) ($case.Name+': exit '+$process.ExitCode)
 Assert-True ($result -like ($case.Expect -f $dir)) ($case.Name+': '+$result)
}
Remove-Item -LiteralPath $fixture -Recurse -Force
Write-Host 'PASS AC8 Integrated.exe: GUI subsystem, icon, version, asInvoker, no build paths; starts Host.ps1 -Action Gui at an install root and Launcher-GUI.ps1 in a package folder'
