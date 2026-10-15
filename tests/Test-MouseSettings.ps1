$ErrorActionPreference='Stop'
# MouseAim-Settings.ini -> runtime config.ini: hud_boresight (2.4.1) is read, range-checked and written into [control],
# also into a runtime config.ini from 2.4.0 that has no hud_boresight line yet.
$repo=Split-Path $PSScriptRoot -Parent;$template=Join-Path $repo 'package-template'
. (Join-Path $template 'MouseAim-Settings.ps1')
$fixture=Join-Path $repo ('native/test-runtime/mouse-settings-'+[guid]::NewGuid().ToString('N'))
$config=Get-Content -LiteralPath (Join-Path $template 'payload/Game/Binaries/Win64/ue4ss/Mods/AC8MouseAim/config.ini') -Raw
$settings=Get-Content -LiteralPath (Join-Path $template 'MouseAim-Settings.ini') -Raw
if((Read-MouseSettings (Join-Path $template 'MouseAim-Settings.ini')).hud_boresight -ne 1){throw 'Default gun cross must be shown'}
$legacy=$config -replace '(?m)^; Reference gun cross[^\r\n]*\r?\n','' -replace '(?m)^hud_boresight=[^\r\n]*\r?\n',''
if($legacy -match 'hud_boresight'){throw 'Fixture still has hud_boresight'}
foreach($case in @(@{name='current';text=$config},@{name='legacy';text=$legacy})){
 $mod=Join-Path $fixture $case.name;New-Item -ItemType Directory -Path (Join-Path $mod 'Scripts') -Force | Out-Null
 Set-Content -LiteralPath (Join-Path $mod 'config.ini') -Value $case.text -NoNewline -Encoding ASCII
 foreach($want in 0,1){
  $ini=Join-Path $fixture "user-$want.ini";Set-Content -LiteralPath $ini -Value ($settings -replace '(?m)^hud_boresight=1',"hud_boresight=$want") -Encoding UTF8
  Apply-MouseSettings (Read-MouseSettings $ini) $mod
  $text=Get-Content -LiteralPath (Join-Path $mod 'config.ini') -Raw;$lines=[regex]::Matches($text,'(?m)^hud_boresight=([^\r\n]*)')
  if($lines.Count -ne 1 -or $lines[0].Groups[1].Value -ne "$want"){throw "$($case.name): hud_boresight=$want not written exactly once"}
  if($text.IndexOf('hud_boresight=') -gt $text.IndexOf('[keybindings]')){throw "$($case.name): hud_boresight outside [control]"}
 }
}
foreach($bad in '2','0.5'){
 $ini=Join-Path $fixture 'bad.ini';Set-Content -LiteralPath $ini -Value ($settings -replace '(?m)^hud_boresight=1',"hud_boresight=$bad") -Encoding UTF8
 $caught=$false;try{Read-MouseSettings $ini|Out-Null}catch{$caught=$true};if(!$caught){throw "hud_boresight=$bad accepted"}
}
# flight_recording (2.4.3): off by default, written into [control] (also into a runtime config without the line), and the
# launcher checkbox's in-place edit keeps every other line of the user's file.
if((Read-MouseSettings (Join-Path $template 'MouseAim-Settings.ini')).flight_recording -ne 0){throw 'Flight recording must be off by default'}
$noRec=$legacy -replace '(?m)^; Flight recording[^\r\n]*\r?\n','' -replace '(?m)^; Launcher: maintenance[^\r\n]*\r?\n','' -replace '(?m)^flight_recording=[^\r\n]*\r?\n',''
foreach($case in @(@{name='rec-current';text=$config},@{name='rec-legacy';text=$noRec})){
 $mod=Join-Path $fixture $case.name;New-Item -ItemType Directory -Path (Join-Path $mod 'Scripts') -Force | Out-Null
 Set-Content -LiteralPath (Join-Path $mod 'config.ini') -Value $case.text -NoNewline -Encoding ASCII
 foreach($want in 1,0){
  $ini=Join-Path $fixture "rec-$want.ini";Set-Content -LiteralPath $ini -Value ($settings -replace '(?m)^flight_recording=0',"flight_recording=$want") -Encoding UTF8
  Apply-MouseSettings (Read-MouseSettings $ini) $mod
  $text=Get-Content -LiteralPath (Join-Path $mod 'config.ini') -Raw;$lines=[regex]::Matches($text,'(?m)^flight_recording=([^\r\n]*)')
  if($lines.Count -ne 1 -or $lines[0].Groups[1].Value -ne "$want"){throw "$($case.name): flight_recording=$want not written exactly once"}
  if($text.IndexOf('flight_recording=') -gt $text.IndexOf('[keybindings]')){throw "$($case.name): flight_recording outside [control]"}
 }
}
$user=Join-Path $fixture 'user-edit.ini';[IO.File]::WriteAllText($user,($settings -replace '(?m)^sensitivity=0\.10','sensitivity=0.137'),(New-Object Text.UTF8Encoding($true)))
$before=[IO.File]::ReadAllText($user)
Set-MouseSettingValue $user 'flight_recording' '1'
$after=[IO.File]::ReadAllText($user)
if((Read-MouseSettings $user).flight_recording -ne 1 -or (Read-MouseSettings $user).sensitivity -ne 0.137){throw 'Checkbox edit lost or changed a value'}
if(($after -replace 'flight_recording=1','flight_recording=0') -ne $before){throw 'Checkbox edit changed other lines'}
$bytes=[IO.File]::ReadAllBytes($user);if($bytes[0] -ne 0xEF -or $after -notmatch "`r`n"){throw 'Checkbox edit changed the BOM or line endings'}
$caught=$false;try{Set-MouseSettingValue $user 'flight_recording' '2'}catch{$caught=$true};if(!$caught -or (Read-MouseSettings $user).flight_recording -ne 1 -or (Test-Path -LiteralPath ($user+'.tmp'))){throw 'Invalid checkbox value accepted or file damaged'}
$old=Join-Path $fixture 'old.ini';[IO.File]::WriteAllText($old,(($settings -replace '(?m)^; Flight recording[^\r\n]*\r?\n','' -replace '(?m)^; Launcher: maintenance[^\r\n]*\r?\n','') -replace '(?m)^flight_recording=0\r?\n',''),(New-Object Text.UTF8Encoding($true)))
Set-MouseSettingValue $old 'flight_recording' '1';if((Read-MouseSettings $old).flight_recording -ne 1){throw 'Missing key not appended'}
# 2.5.0: WAR is the startup default (template, runtime config and missing line); a saved PEACE (0 or legacy 1) moves to WAR
# exactly once, recorded in migrations.json; a later PEACE choice stays; an unreadable file is not marked as migrated.
if((Read-MouseSettings (Join-Path $template 'MouseAim-Settings.ini')).control_mode -ne 3 -or $config -notmatch '(?m)^control_mode=3\r?$'){throw 'WAR must be the default control mode'}
$noMode=Join-Path $fixture 'no-mode.ini';[IO.File]::WriteAllText($noMode,($settings -replace '(?m)^control_mode=3\r?\n',''));if((Read-MouseSettings $noMode).control_mode -ne 3){throw 'Missing control_mode must mean WAR'}
foreach($case in @(@{saved='0';want=3;changed=$true},@{saved='1';want=3;changed=$true},@{saved='3';want=3;changed=$false},@{saved='4';want=3;changed=$false})){
 $data=Join-Path $fixture ('migrate-'+$case.saved);New-Item -ItemType Directory -Path $data -Force | Out-Null
 $ini=Join-Path $data 'MouseAim-Settings.ini';[IO.File]::WriteAllText($ini,($settings -replace '(?m)^control_mode=3',('control_mode='+$case.saved)),(New-Object Text.UTF8Encoding($true)))
 $before=[IO.File]::ReadAllText($ini)
 $applied=@(Invoke-AC8SettingsMigrations $data)
 if($applied -join ',' -ne 'war-default-2.5.0'){throw "saved $($case.saved): migration not reported"}
 if((Read-MouseSettings $ini).control_mode -ne $case.want){throw "saved $($case.saved): not WAR after migration"}
 if(([IO.File]::ReadAllText($ini) -ne $before) -ne $case.changed){throw "saved $($case.saved): file changed unexpectedly"}
 Set-MouseSettingValue $ini 'control_mode' '0'
 if(@(Invoke-AC8SettingsMigrations $data).Count -or (Read-MouseSettings $ini).control_mode -ne 0){throw "saved $($case.saved): later PEACE choice overwritten"}
 if(@((Get-Content -LiteralPath (Join-Path $data 'migrations.json') -Raw | ConvertFrom-Json).applied) -join ',' -ne 'war-default-2.5.0'){throw 'migrations.json not recorded once'}
}
$fresh=Join-Path $fixture 'migrate-empty';New-Item -ItemType Directory -Path $fresh -Force | Out-Null
if(@(Invoke-AC8SettingsMigrations $fresh) -join ',' -ne 'war-default-2.5.0' -or (Test-Path -LiteralPath (Join-Path $fresh 'MouseAim-Settings.ini'))){throw 'Data without settings must only record the migration'}
$broken=Join-Path $fixture 'migrate-broken';New-Item -ItemType Directory -Path $broken -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $broken 'MouseAim-Settings.ini'),"control_mode=0`r`nsensitivity=abc`r`n")
if(@(Invoke-AC8SettingsMigrations $broken).Count -or (Test-Path -LiteralPath (Join-Path $broken 'migrations.json'))){throw 'Unreadable settings must not be marked as migrated'}
Remove-Item -LiteralPath $fixture -Recurse -Force
Write-Host 'PASS WAR default and one-time PEACE->WAR migration; hud_boresight and flight_recording defaults, 0/1 written once into [control] (also for runtime configs without the line), invalid values rejected, launcher checkbox edit keeps the rest of the file'
