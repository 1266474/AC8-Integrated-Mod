$ErrorActionPreference='Stop'
# AC8 Integrated.exe (native\launcher, 2.5.0): the player tool as its own Windows application. A Windows-subsystem .NET
# program with the AC8 icon, version information and an asInvoker manifest, no build-machine paths; it hosts the
# launcher scripts in its own process (Host.ps1 -Action Gui at an install root, Launcher-GUI.ps1 in a package folder).
# Checked with --dry-run (nothing started) and --smoke (Launcher-GUI.ps1 -SmokeTest inside the exe: real WPF buttons,
# busy state and the asynchronous worker, without showing a window). Needs native\launcher\build.cmd first.
$repo=Split-Path $PSScriptRoot -Parent;$template=Join-Path $repo 'package-template'
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
Assert-True ($info.ProductName -eq 'AC8 Integrated' -and $info.FileDescription -eq 'AC8 Integrated' -and $info.FileVersion -eq ($version -replace '-.*$','') -and $info.CompanyName -eq 'CreeperUX') ('version information: '+$info.FileVersion)
Add-Type -AssemblyName System.Drawing
$icon=[Drawing.Icon]::ExtractAssociatedIcon($exe);Assert-True ($icon.Width -ge 32) 'embedded icon';$icon.Dispose()
$fixture=Join-Path $repo ('native/test-runtime/launcher-'+[guid]::NewGuid().ToString('N'))
foreach($case in @(
 @{Name='install root';Files=@('Host.ps1','Launcher-GUI.ps1');Code=0;Expect='host: {0}\Host.ps1 -Action Gui'},
 @{Name='package folder';Files=@('Launcher-GUI.ps1');Code=0;Expect='launcher: {0}\Launcher-GUI.ps1'},
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
# The launcher itself, hosted in the exe (no powershell.exe child).
$package=Join-Path $fixture 'package with space';Copy-Item -LiteralPath $template -Destination $package -Recurse;Copy-Item -LiteralPath $exe -Destination $package
$out=Join-Path $fixture 'smoke.txt'
$process=Start-Process -FilePath (Join-Path $package 'AC8 Integrated.exe') -ArgumentList @('--smoke',('"'+$out+'"')) -Wait -PassThru
$result=[IO.File]::ReadAllText($out,[Text.Encoding]::UTF8)
Assert-True ($process.ExitCode -eq 0 -and $result -match 'exit=0' -and $result -match 'PASS real GUI button') ('hosted launcher smoke: '+$result)
Remove-Item -LiteralPath $fixture -Recurse -Force
Write-Host 'PASS AC8 Integrated.exe: GUI subsystem, icon, version, asInvoker, no build paths; Host.ps1 -Action Gui at an install root, Launcher-GUI.ps1 in a package folder; the launcher runs inside the exe (smoke)'
