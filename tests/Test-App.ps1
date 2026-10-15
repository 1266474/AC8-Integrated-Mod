$ErrorActionPreference='Stop'
# Installed app (2.5.0) end to end in a temporary folder: setup, import of a portable package, data layout, signed
# updates and their refusals, rollback, offline and online repair, pruning, mod mode, uninstall, registration (test key
# and shortcut only), the signing scripts, the launcher's update check and the launch diagnostics. No game, Steam or
# network is used; nothing outside the fixture changes except a temporary HKCU\Software\AC8IntegratedTest key.
$repo=Split-Path $PSScriptRoot -Parent;$template=Join-Path $repo 'package-template'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Security
$fixture=Join-Path $repo ('native/test-runtime/app-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$powershell=Join-Path $PSHOME 'powershell.exe'
. (Join-Path $template 'app\App-Core.ps1')
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(3072);$rsa.PersistKeyInCsp=$false
$other=New-Object Security.Cryptography.RSACryptoServiceProvider(3072);$other.PersistKeyInCsp=$false
$publicXml=$rsa.ToXmlString($false)
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function Write-FileList([string]$Dir){
 $lines=@(foreach($file in @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName)){
  if($file.FullName -eq (Join-Path $Dir 'FILES.sha256')){continue}
  (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()+'  '+$file.FullName.Substring($Dir.Length+1).Replace('\','/')
 })
 [IO.File]::WriteAllText((Join-Path $Dir 'FILES.sha256'),(($lines -join "`n")+"`n"),(New-Object Text.UTF8Encoding($false)))
}
function New-TestRelease([string]$Version,[scriptblock]$Change={},[string]$KeyXml=$publicXml,[switch]$AfterList){
 $name='AC8-Integrated-v'+$Version+'-share';$base=Join-Path $fixture ('build-'+[guid]::NewGuid().ToString('N'));$dir=Join-Path $base $name
 New-Item -ItemType Directory -Path $base | Out-Null;Copy-Item -LiteralPath $template -Destination $dir -Recurse
 [IO.File]::WriteAllText((Join-Path $dir 'package-info.json'),('{"version":"'+$Version+'","status":"release"}'))
 [IO.File]::WriteAllText((Join-Path $dir 'app\update-key.xml'),$KeyXml)
 if(!$AfterList){& $Change $dir}
 Write-FileList $dir
 if($AfterList){& $Change $dir}
 $zip=Join-Path $base ($name+'.zip')
 [IO.Compression.ZipFile]::CreateFromDirectory($dir,$zip,[IO.Compression.CompressionLevel]::Fastest,$true)
 return $zip
}
function New-TestFeed([string]$Zip,[string]$Tag='',$Signer=$rsa,[scriptblock]$EditManifest={}){
 $name=[IO.Path]::GetFileName($Zip);$version=([regex]::Match($name,'^AC8-Integrated-v(.+)-share\.zip$')).Groups[1].Value
 $feed=Join-Path $fixture ('feed-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $feed | Out-Null
 Copy-Item -LiteralPath $Zip -Destination $feed
 $manifest=[ordered]@{schema=1;product='AC8-Integrated';version=$version;asset=$name;sha256=(Get-FileHash -LiteralPath $Zip).Hash;size=(Get-Item -LiteralPath $Zip).Length}
 & $EditManifest $manifest
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject ([pscustomobject]$manifest)))
 [IO.File]::WriteAllBytes((Join-Path $feed 'update-manifest.json'),$bytes)
 [IO.File]::WriteAllText((Join-Path $feed 'update-manifest.json.sig'),[Convert]::ToBase64String($Signer.SignData($bytes,'SHA256')))
 $tagName=if($Tag){$Tag}else{'v'+$version}
 $assets=@(foreach($file in $name,'update-manifest.json','update-manifest.json.sig'){[pscustomobject]@{name=$file;size=(Get-Item -LiteralPath (Join-Path $feed $file)).Length;browser_download_url=('https://github.com/CreeperUX/AC8-Integrated-Mod/releases/download/'+$tagName+'/'+$file)}})
 $release=ConvertTo-Json -Depth 5 -InputObject ([pscustomobject]@{tag_name=$tagName;html_url='https://example.invalid/releases/'+$tagName;assets=$assets})
 [IO.File]::WriteAllText((Join-Path $feed 'release.json'),$release);[IO.File]::WriteAllText((Join-Path $feed ('release-'+$tagName+'.json')),$release)
 return $feed
}
function Invoke-TestHost([string]$Root,[string[]]$Arguments){
 $output=@(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Host.ps1') @Arguments 2>&1 | ForEach-Object {[string]$_})
 return [pscustomobject]@{Code=$LASTEXITCODE;Text=($output -join "`n")}
}
function Get-TestState([string]$Root){$state=[IO.File]::ReadAllText((Join-Path $Root 'app.json')) | ConvertFrom-Json;return $state}
function New-TestGame([string]$Name){
 $game=Join-Path $fixture $Name;$w64=Join-Path $game 'Game\Binaries\Win64';New-Item -ItemType Directory -Path $w64 -Force | Out-Null
 [IO.File]::WriteAllBytes((Join-Path $w64 'AceCombat8.exe'),[byte[]](1,2,3));return $game
}
$checks=0

# ---- setup ----
$zip250=New-TestRelease '2.5.0'
$install=Join-Path $fixture 'Programs\AC8 Integrated'
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $template 'app\Install-App.ps1') -Zip $zip250 -InstallRoot $install -NoImport -Yes -NoRegister -NoLaunch | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'setup failed'
$state=Get-TestState $install
Assert-True ($state.current -eq '2.5.0' -and !$state.previous) 'app.json after setup'
$v250=Join-Path $install 'versions\2.5.0';$data=Join-Path $install 'data'
foreach($pair in @(@('Host.ps1','Host.ps1'),@('App-Core.ps1','App-Core.ps1'),@('Start-AC8-From-Steam.cmd','Start-AC8-From-Steam.cmd'),@('update-key.xml','trust\update-key.xml'))){
 Assert-True ((Get-FileHash (Join-Path $v250 ('app\'+$pair[0]))).Hash -eq (Get-FileHash (Join-Path $install $pair[1])).Hash) ('host file '+$pair[1])
}
foreach($name in 'MouseAim-Settings.ini','Keybindings.ini','features.ini','game-path.txt','steam-path.txt','ue4ss-mods\README.txt','migrations.json','update-cache\2.5.0\package.json','update-cache\2.5.0\AC8-Integrated-v2.5.0-share.zip'){Assert-True (Test-Path -LiteralPath (Join-Path $data $name)) ('data missing '+$name)}
$option='"'+(Join-Path $install 'Start-AC8-From-Steam.cmd')+'" %command%'
Assert-True ((Get-Content -LiteralPath (Join-Path $data 'Steam-Launch-Option.txt') -Raw -Encoding UTF8).Trim() -eq $option) 'launch option file'
Assert-True (!@(Get-AC8PackageFileProblems $v250).Count) 'installed version files'
Assert-True ((Get-Content -LiteralPath (Join-Path $v250 'FILES.sha256') -Raw -Encoding UTF8) -match ([string][char]0x5F00+[char]0x59CB+[char]0x4F7F+[char]0x7528+'\.md')) 'file list names the Chinese files'
$ansi=Join-Path $fixture 'ansi-list';New-Item -ItemType Directory -Path $ansi | Out-Null;$name=[string][char]0x5F00+[char]0x59CB+'.txt';[IO.File]::WriteAllText((Join-Path $ansi $name),'x')
if([Text.Encoding]::Default.GetString([Text.Encoding]::Default.GetBytes($name)) -eq $name){
 [IO.File]::WriteAllText((Join-Path $ansi 'FILES.sha256'),((Get-FileHash (Join-Path $ansi $name)).Hash.ToLowerInvariant()+'  '+$name+"`n"),[Text.Encoding]::Default)
 Assert-True (!@(Get-AC8PackageFileProblems $ansi).Count) 'file list from an ANSI code page'
}
Assert-True ((Get-Content -LiteralPath (Join-Path $v250 'app-version.json') -Raw | ConvertFrom-Json).version -eq '2.5.0') 'app-version.json'
$checks++
# The package scripts resolve the shared data folder and the fixed Steam entry.
$probe=& $powershell -NoProfile -ExecutionPolicy Bypass -Command ". ([IO.Path]::Combine('$v250','PowerShell-Compat.ps1'));(Get-AC8DataRoot '$v250')+'|'+(Get-AC8SteamEntry '$v250')"
Assert-True ($probe -eq ($data+'|'+(Join-Path $install 'Start-AC8-From-Steam.cmd'))) ('layout resolution: '+$probe)
$game=New-TestGame 'game';$steamExe=Join-Path $fixture 'Steam\steam.exe';New-Item -ItemType Directory -Path (Split-Path $steamExe) -Force | Out-Null;[IO.File]::WriteAllBytes($steamExe,[byte[]](0))
$saved=& $powershell -NoProfile -ExecutionPolicy Bypass -Command ". ([IO.Path]::Combine('$v250','Gui-Core.ps1'));Save-AC8GuiSettings '$v250' '$game' '$steamExe' 'guidance'"
Assert-True ($saved -eq $option) 'GUI launch option in installed mode'
Assert-True ((Get-Content -LiteralPath (Join-Path $data 'game-path.txt') -Raw -Encoding UTF8).Trim() -eq $game -and !(Get-Content -LiteralPath (Join-Path $v250 'game-path.txt') -Raw)) 'GUI settings must go to data'
Assert-True ((Get-Content -LiteralPath (Join-Path $data 'features.ini') -Raw) -match 'missile_mode=guidance') 'features in data'
$checks++
# Mod mode: the original-launch marker lives in data, where the host's Steam entry looks for it.
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $v250 'Mod-Mode.ps1') -Action Disable | Out-Null
Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $data 'mod-disabled.flag')) -and !(Test-Path -LiteralPath (Join-Path $v250 'mod-disabled.flag'))) 'mod disabled marker in data'
Assert-True ((Get-Content -LiteralPath (Join-Path $install 'Start-AC8-From-Steam.cmd') -Raw) -match [regex]::Escape('if exist "%~dp0data\mod-disabled.flag" goto original')) 'host entry checks the data marker'
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $v250 'Mod-Mode.ps1') -Action Enable | Out-Null
Assert-True ($LASTEXITCODE -eq 0 -and !(Test-Path -LiteralPath (Join-Path $data 'mod-disabled.flag'))) 'mod enabled'
$checks++
$status=Invoke-TestHost $install @('-Action','Status')
Assert-True ($status.Code -eq 0 -and ($status.Text | ConvertFrom-Json).current -eq '2.5.0') 'host status'
$checks++

# ---- import of a portable package (found through the Steam launch option) ----
$portable=Join-Path $fixture 'Mods\AC8 Portable';Copy-Item -LiteralPath $template -Destination $portable -Recurse
$ini=Join-Path $portable 'MouseAim-Settings.ini';[IO.File]::WriteAllText($ini,(([IO.File]::ReadAllText($ini) -replace '(?m)^sensitivity=0\.10','sensitivity=0.23') -replace '(?m)^control_mode=3','control_mode=0'),(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $portable 'features.ini'),"missile_mode=none`r`n")
[IO.File]::WriteAllText((Join-Path $portable 'Keybindings.ini'),"[bindings]`r`nfree_look=C`r`nfree_look_zoom=C`r`n")
New-Item -ItemType Directory -Path (Join-Path $portable 'ue4ss-mods\TestMod\Scripts') -Force | Out-Null;[IO.File]::WriteAllText((Join-Path $portable 'ue4ss-mods\TestMod\Scripts\main.lua'),'print("x")')
$before=@{};foreach($file in Get-ChildItem -LiteralPath $portable -Recurse -File){$before[$file.FullName]=(Get-FileHash $file.FullName).Hash}
$steamRoot=Join-Path $fixture 'SteamRoot';$config=Join-Path $steamRoot 'userdata\12345\config';New-Item -ItemType Directory -Path $config -Force | Out-Null
$vdfOption=('"'+$portable+'\Start-AC8-From-Steam.cmd" %command%').Replace('\','\\').Replace('"','\"')
[IO.File]::WriteAllText((Join-Path $config 'localconfig.vdf'),"`"UserLocalConfigStore`"`n{`n `"Software`"`n {`n  `"Valve`"`n  {`n   `"Steam`"`n   {`n    `"apps`"`n    {`n     `"2288340`"`n     {`n      `"LaunchOptions`"  `"$vdfOption`"`n     }`n    }`n   }`n  }`n }`n}`n")
Assert-True ((Find-AC8PortablePackage '' $steamRoot) -eq $portable) 'portable package from the Steam launch option'
$managedRoot=Join-Path $fixture 'outputs';New-Item -ItemType Directory -Path $managedRoot | Out-Null
[IO.File]::WriteAllText((Join-Path $managedRoot 'AC8-Managed-Packages.json'),'{"activePackage":"Pkg-candidate","packages":[]}')
Copy-Item -LiteralPath $template -Destination (Join-Path $managedRoot 'Pkg-candidate') -Recurse
$managedConfig=Join-Path $fixture 'SteamRoot2\userdata\777\config';New-Item -ItemType Directory -Path $managedConfig -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $managedConfig 'localconfig.vdf'),("`"2288340`"`n{`n `"LaunchOptions`" `""+('"'+$managedRoot+'\Start-AC8-From-Steam.cmd" %command%').Replace('\','\\').Replace('"','\"')+"`"`n}`n"))
Assert-True ((Find-AC8PortablePackage '' (Join-Path $fixture 'SteamRoot2')) -eq (Join-Path $managedRoot 'Pkg-candidate')) 'managed package layout'
Assert-True ($null -eq (Find-AC8PortablePackage '' (Join-Path $fixture 'NoSteam'))) 'no Steam, no import'
[IO.File]::WriteAllText((Join-Path $portable 'active-session.json'),'{}')
$install2=Join-Path $fixture 'Programs2\AC8 Integrated'
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $template 'app\Install-App.ps1') -Zip $zip250 -InstallRoot $install2 -Yes -NoRegister -NoLaunch -SteamRoot $steamRoot | Out-Null
Assert-True ($LASTEXITCODE -ne 0 -and !(Test-Path -LiteralPath $install2)) 'portable package with an unfinished session must not be imported'
Remove-Item -LiteralPath (Join-Path $portable 'active-session.json')
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $template 'app\Install-App.ps1') -Zip $zip250 -InstallRoot $install2 -Yes -NoRegister -NoLaunch -SteamRoot $steamRoot | Out-Null
Assert-True ($LASTEXITCODE -eq 0) 'setup with import'
$data2=Join-Path $install2 'data'
. (Join-Path $template 'MouseAim-Settings.ps1');. (Join-Path $template 'Keybinding-Settings.ps1')
$values=Read-MouseSettings (Join-Path $data2 'MouseAim-Settings.ini')
Assert-True ($values.sensitivity -eq 0.23 -and $values.control_mode -eq 3) 'imported sensitivity kept, PEACE migrated to WAR'
Assert-True ((Get-Content -LiteralPath (Join-Path $data2 'features.ini') -Raw) -match 'missile_mode=none') 'imported features'
Assert-True ((Read-AC8Keybindings (Join-Path $data2 'Keybindings.ini')).free_look -eq 'C' -and @(Get-ChildItem -LiteralPath (Join-Path $data2 'repair-backups') -Recurse -Filter 'Keybindings.ini').Count -eq 1) 'conflicting imported keybindings rebuilt with a backup'
Assert-True (Test-Path -LiteralPath (Join-Path $data2 'ue4ss-mods\TestMod\Scripts\main.lua')) 'imported extra mod'
foreach($file in Get-ChildItem -LiteralPath $portable -Recurse -File){Assert-True ($before[$file.FullName] -eq (Get-FileHash $file.FullName).Hash) ('portable file changed: '+$file.FullName)}
Assert-True (@(Get-ChildItem -LiteralPath $portable -Recurse -File).Count -eq $before.Count) 'portable package gained files'
$checks++

# ---- signed updates and refusals ----
$zip251=New-TestRelease '2.5.1' {param($dir)
 Add-Content -LiteralPath (Join-Path $dir 'app\Host.ps1') -Value '# 2.5.1' -Encoding UTF8
 $settings=Join-Path $dir 'MouseAim-Settings.ps1';[IO.File]::WriteAllText($settings,([IO.File]::ReadAllText($settings).Replace('flight_recording=0;control_mode=3;','flight_recording=0;test_new_key=0;control_mode=3;')),(New-Object Text.UTF8Encoding($true)))
}
$feed251=New-TestFeed $zip251
$v=[IO.File]::ReadAllText((Join-Path $data 'MouseAim-Settings.ini'));[IO.File]::WriteAllText((Join-Path $data 'MouseAim-Settings.ini'),($v -replace '(?m)^sensitivity=0\.10','sensitivity=0.31'),(New-Object Text.UTF8Encoding($true)))
$refusals=@(
 @{Name='bad signature';Feed=(New-TestFeed $zip251 '' $other);Code='UPDATE_SIGNATURE'},
 @{Name='hash mismatch';Feed=(New-TestFeed $zip251 '' $rsa {param($m) $m.sha256='0'*64});Code='UPDATE_HASH'},
 @{Name='version differs from tag';Feed=(New-TestFeed $zip251 'v2.5.9');Code='UPDATE_MANIFEST'},
 @{Name='unlisted file';Feed=(New-TestFeed (New-TestRelease '2.5.1' {param($dir) [IO.File]::WriteAllText((Join-Path $dir 'extra.ps1'),'x')} -AfterList));Code='PACKAGE_INVALID'},
 @{Name='old package without host';Feed=(New-TestFeed (New-TestRelease '2.5.1' {param($dir) Remove-Item -LiteralPath (Join-Path $dir 'app') -Recurse}));Code='PACKAGE_INVALID'}
)
foreach($case in $refusals){
 $result=Invoke-TestHost $install @('-Action','Update','-Feed',$case.Feed,'-Yes','-NoRegister','-NoLaunch')
 Assert-True ($result.Code -ne 0 -and $result.Text -match $case.Code) ($case.Name+' was not refused: '+$result.Text)
 Assert-True ((Get-TestState $install).current -eq '2.5.0' -and !(Test-Path -LiteralPath (Join-Path $install 'versions\2.5.1'))) ($case.Name+' changed the installation')
}
$slip=Join-Path $fixture 'slip';New-Item -ItemType Directory -Path $slip | Out-Null;$slipZip=Join-Path $slip 'AC8-Integrated-v2.5.1-share.zip'
$archive=[IO.Compression.ZipFile]::Open($slipZip,'Create');try{$entry=$archive.CreateEntry('AC8-Integrated-v2.5.1-share/../../evil.txt');$writer=New-Object IO.StreamWriter($entry.Open());$writer.Write('x');$writer.Dispose()}finally{$archive.Dispose()}
$result=Invoke-TestHost $install @('-Action','Update','-Feed',(New-TestFeed $slipZip),'-Yes','-NoRegister','-NoLaunch')
Assert-True ($result.Code -ne 0 -and $result.Text -match 'PACKAGE_INVALID' -and !@(Get-ChildItem -LiteralPath $install -Recurse -Filter 'evil.txt').Count) ('zip path traversal: '+$result.Text)
[IO.File]::WriteAllText((Join-Path $data 'active-session.json'),'{}')
$result=Invoke-TestHost $install @('-Action','Update','-Feed',$feed251,'-Yes','-NoRegister','-NoLaunch')
Assert-True ($result.Code -ne 0 -and $result.Text -match 'APP_BUSY' -and (Get-TestState $install).current -eq '2.5.0') 'update during an unfinished session'
Remove-Item -LiteralPath (Join-Path $data 'active-session.json')
$result=Invoke-TestHost $install @('-Action','Update','-Feed',(New-TestFeed $zip250),'-Yes','-NoRegister','-NoLaunch')
Assert-True ($result.Code -eq 0 -and !(Test-Path -LiteralPath (Join-Path $install 'versions\2.5.1')) -and (Get-TestState $install).current -eq '2.5.0') 'same version is not an update'
$checks++
$result=Invoke-TestHost $install @('-Action','Update','-Feed',$feed251,'-Yes','-NoRegister','-NoLaunch')
Assert-True ($result.Code -eq 0) ('update failed: '+$result.Text)
$state=Get-TestState $install
Assert-True ($state.current -eq '2.5.1' -and $state.previous -eq '2.5.0') 'app.json after update'
Assert-True ((Get-Content -LiteralPath (Join-Path $install 'Host.ps1') -Raw) -match '# 2\.5\.1') 'host updated from the new version'
Assert-True ((Read-MouseSettings (Join-Path $data 'MouseAim-Settings.ini')).sensitivity -eq 0.31) 'player settings kept across the update'
Assert-True ((Test-Path -LiteralPath (Join-Path $data 'update-cache\2.5.1\package.json')) -and !@(Get-ChildItem -LiteralPath (Join-Path $data 'update-cache') -Directory -Filter 'incoming-*').Count) 'update cache'
$checks++

# ---- rollback: settings the newer version wrote are made readable for the older one ----
Add-Content -LiteralPath (Join-Path $data 'MouseAim-Settings.ini') -Value 'test_new_key=1' -Encoding UTF8
$result=Invoke-TestHost $install @('-Action','Rollback','-Yes','-NoRegister')
Assert-True ($result.Code -eq 0) ('rollback failed: '+$result.Text)
$state=Get-TestState $install
Assert-True ($state.current -eq '2.5.0' -and $state.previous -eq '2.5.1') 'app.json after rollback'
$values=Read-MouseSettings (Join-Path $data 'MouseAim-Settings.ini')
Assert-True ($values.sensitivity -eq 0.31) 'rollback kept the readable settings'
Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $data 'repair-backups') -Recurse -Filter 'MouseAim-Settings.ini').Count -eq 1) 'rollback backed up the unreadable settings'
$checks++

# ---- repair: offline from the cached package, online from the release of the same version ----
$target=Join-Path $install 'versions\2.5.0\Launch-Offline.ps1';Add-Content -LiteralPath $target -Value '# damaged' -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $install 'versions\2.5.0\Setup.ps1')
[IO.File]::WriteAllText((Join-Path $install 'App-Core.ps1'),'# damaged')
$quick=@(Invoke-AC8AppRepair $install -Quick -NoRegister)
Assert-True (!@($quick | Where-Object Status -eq 'problem').Count -and @($quick | Where-Object Status -eq 'fixed').Count -eq 2) ('quick repair: '+(($quick | ForEach-Object Message) -join ' / '))
Assert-True (!@(Get-AC8PackageFileProblems (Join-Path $install 'versions\2.5.0')).Count) 'version files restored'
Assert-True ((Get-FileHash (Join-Path $install 'App-Core.ps1')).Hash -eq (Get-FileHash (Join-Path $install 'versions\2.5.1\app\App-Core.ps1')).Hash) 'host files follow the newest intact version'
Remove-AC8Tree (Join-Path $data 'update-cache\2.5.0');Add-Content -LiteralPath $target -Value '# damaged' -Encoding UTF8
$quick=@(Invoke-AC8AppRepair $install -Quick -NoRegister)
Assert-True (@($quick | Where-Object Status -eq 'problem').Count -eq 1) 'without cache the quick check reports the damage'
$result=Invoke-TestHost $install @('-Action','Session')
Assert-True ($result.Code -ne 0 -and $result.Text -match 'APP_DAMAGED' -and $result.Text -match 'Launch-Offline\.ps1') ('launch with damaged files must stop: '+$result.Text)
$full=@(Invoke-AC8AppRepair $install -Feed (New-TestFeed $zip250) -NoRegister)
Assert-True (@($full | Where-Object {$_.Item -eq '程序文件' -and $_.Status -eq 'fixed'}).Count -eq 1 -and !@(Get-AC8PackageFileProblems (Join-Path $install 'versions\2.5.0')).Count) 'online repair of the same version'
Assert-True (Test-Path -LiteralPath (Join-Path $data 'update-cache\2.5.0\package.json')) 'online repair refreshed the cache'
[IO.File]::WriteAllText((Join-Path $install 'app.json'),'{broken')
$quick=@(Invoke-AC8AppRepair $install -Quick -NoRegister)
Assert-True ((Get-TestState $install).current -eq '2.5.1' -and @($quick | Where-Object Item -eq '版本记录').Count) 'app.json rebuilt from the installed versions'
$full=@(Invoke-AC8AppRepair $install -NoRegister -Offline)
Assert-True (@($full | Where-Object {$_.Item -eq '游戏目录' -and $_.Status -eq 'ok'}).Count -eq 1) 'game folder check'
New-Item -ItemType Directory -Path (Join-Path $game 'Game\Binaries\Win64\ue4ss') | Out-Null
$full=@(Invoke-AC8AppRepair $install -NoRegister -Offline)
Assert-True (@($full | Where-Object {$_.Item -eq '游戏目录' -and $_.Status -eq 'problem'}).Count -eq 1) 'loader leftovers reported'
$checks++

# ---- uninstall refuses with loader files in the game folder, then removes the app and keeps data ----
$result=Invoke-TestHost $install @('-Action','Uninstall','-Yes','-NoRegister')
Assert-True ($result.Code -ne 0 -and $result.Text -match 'LOADER_PRESENT' -and (Test-Path -LiteralPath (Join-Path $install 'versions'))) 'uninstall with loader files must stop'
Remove-Item -LiteralPath (Join-Path $game 'Game\Binaries\Win64\ue4ss')
# pruning: a third version removes the oldest
$result=Invoke-TestHost $install @('-Action','Update','-Feed',(New-TestFeed (New-TestRelease '2.5.2')),'-Yes','-NoRegister','-NoLaunch')
Assert-True ($result.Code -eq 0) ('second update: '+$result.Text)
$names=@(Get-ChildItem -LiteralPath (Join-Path $install 'versions') -Directory -Force | ForEach-Object Name | Sort-Object)
Assert-True (($names -join ',') -eq '2.5.1,2.5.2' -and !(Test-Path -LiteralPath (Join-Path $data 'update-cache\2.5.0'))) ('pruned versions: '+($names -join ','))
$result=Invoke-TestHost $install @('-Action','Uninstall','-Yes','-NoRegister')
Assert-True ($result.Code -eq 0) ('uninstall failed: '+$result.Text)
Assert-True ((@(Get-ChildItem -LiteralPath $install -Force | ForEach-Object Name) -join ',') -eq 'data' -and (Test-Path -LiteralPath (Join-Path $data 'MouseAim-Settings.ini'))) 'uninstall keeps only data'
$result=Invoke-TestHost $install2 @('-Action','Uninstall','-Yes','-NoRegister','-RemoveData')
Assert-True ($result.Code -eq 0 -and !(Test-Path -LiteralPath $install2)) 'uninstall with data removal'
$result=& $powershell -NoProfile -ExecutionPolicy Bypass -Command ". '$(Join-Path $template 'app\App-Core.ps1')';try{Invoke-AC8AppUninstall '$fixture' `$true -NoRegister;'removed'}catch{'refused'}"
Assert-True ($result -eq 'refused' -and (Test-Path -LiteralPath $portable)) 'uninstall refuses a folder that is not an installation'
$checks++

# ---- registration (temporary test key and shortcut only) ----
$key='HKCU:\Software\AC8IntegratedTest\'+[guid]::NewGuid().ToString('N');$link=Join-Path $fixture 'AC8 Integrated.lnk'
$install3=Join-Path $fixture 'Programs3\AC8 Integrated'
& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $template 'app\Install-App.ps1') -Zip $zip250 -InstallRoot $install3 -NoImport -Yes -NoRegister -NoLaunch | Out-Null
try{
 Register-AC8App $install3 '2.5.0' $key $link
 $props=Get-ItemProperty -LiteralPath $key
 Assert-True ($props.DisplayName -eq 'AC8 Integrated' -and $props.DisplayVersion -eq '2.5.0' -and $props.InstallLocation -eq $install3 -and $props.UninstallString -match [regex]::Escape((Join-Path $install3 'Host.ps1')) -and $props.UninstallString -match '-Action Uninstall' -and $props.NoModify -eq 1) 'uninstall entry'
 $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($link)
 Assert-True ($shortcut.Arguments -match [regex]::Escape('"'+(Join-Path $install3 'Host.ps1')+'"') -and $shortcut.Arguments -match '-Action Gui' -and $shortcut.IconLocation -match 'AC8\.ico') 'Start menu shortcut'
 Assert-True (Test-AC8AppRegistered $install3 $key $link) 'registered'
 Unregister-AC8App $key $link
 Assert-True (!(Test-Path -LiteralPath $key) -and !(Test-Path -LiteralPath $link)) 'unregistered'
}finally{if(Test-Path -LiteralPath 'HKCU:\Software\AC8IntegratedTest'){Remove-Item -LiteralPath 'HKCU:\Software\AC8IntegratedTest' -Recurse -Force}}
$checks++

# ---- release signing scripts ----
$keyDir=Join-Path ([IO.Path]::GetTempPath()) ('ac8-signing-test-'+[guid]::NewGuid().ToString('N'));$private=Join-Path $keyDir 'key.dpapi';$public=Join-Path $fixture 'release-key.xml'
try{
 $caught=$false;try{& (Join-Path $repo 'scripts\new-update-key.ps1') -PrivateKeyPath (Join-Path $repo 'native\test-runtime\inside.dpapi') -PublicKeyPath $public}catch{$caught=$true}
 Assert-True ($caught -and !(Test-Path -LiteralPath (Join-Path $repo 'native\test-runtime\inside.dpapi'))) 'private key inside the repository must be refused'
 & (Join-Path $repo 'scripts\new-update-key.ps1') -PrivateKeyPath $private -PublicKeyPath $public | Out-Null
 Assert-True ((Get-Content -LiteralPath $public -Raw) -notmatch '<D>' -and (Get-Content -LiteralPath $public -Raw) -match '<Modulus>') 'public key only'
 $caught=$false;try{& (Join-Path $repo 'scripts\new-update-key.ps1') -PrivateKeyPath $private -PublicKeyPath $public}catch{$caught=$true};Assert-True $caught 'existing private key must not be replaced'
 $signedZip=New-TestRelease '2.6.0' {} ([IO.File]::ReadAllText($public))
 $out=Join-Path $fixture 'signed';& (Join-Path $repo 'scripts\sign-release.ps1') -Zip $signedZip -PrivateKeyPath $private -OutDir $out | Out-Null
 $bytes=[IO.File]::ReadAllBytes((Join-Path $out 'update-manifest.json'))
 Assert-True (Test-AC8UpdateSignature $bytes ([IO.File]::ReadAllText((Join-Path $out 'update-manifest.json.sig'))) $public) 'signed manifest verifies'
 $manifest=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
 Assert-True ($manifest.version -eq '2.6.0' -and $manifest.sha256 -eq (Get-FileHash $signedZip).Hash -and $manifest.size -eq (Get-Item $signedZip).Length) 'manifest content'
 $bytes[10]=$bytes[10] -bxor 1;Assert-True (!(Test-AC8UpdateSignature $bytes ([IO.File]::ReadAllText((Join-Path $out 'update-manifest.json.sig'))) $public)) 'changed manifest must fail'
 $caught=$false;try{& (Join-Path $repo 'scripts\sign-release.ps1') -Zip $zip250 -PrivateKeyPath $private -OutDir (Join-Path $fixture 'signed2')}catch{$caught=$true}
 Assert-True $caught 'a package with another public key must not be signed'
}finally{if(Test-Path -LiteralPath $keyDir){Remove-Item -LiteralPath $keyDir -Recurse -Force}}
$checks++

# ---- launcher update check ----
$portableCheck=Join-Path $fixture 'check-portable';Copy-Item -LiteralPath $template -Destination $portableCheck -Recurse
[IO.File]::WriteAllText((Join-Path $portableCheck 'package-info.json'),'{"version":"2.5.0","status":"release"}')
$result=& $powershell -NoProfile -ExecutionPolicy Bypass -Command ". (Join-Path '$portableCheck' 'Gui-Core.ps1');`$r=Invoke-AC8GuiUpdateCheck '$portableCheck' `$false '$feed251';`$d=Test-AC8UpdateCheckDue '$portableCheck';`$q=Invoke-AC8GuiUpdateCheck '$portableCheck' `$true '$(Join-Path $fixture 'no-feed')';[string]`$r.Update+'|'+`$r.Installed+'|'+`$d+'|'+`$q.Success+'|'+[string]`$q.Update"
Assert-True ($result -eq '2.5.1|False|False|True|') ('launcher update check: '+$result)
$settings=Get-Content -LiteralPath (Join-Path $portableCheck 'app-settings.json') -Raw | ConvertFrom-Json
Assert-True ($settings.auto_update_check -eq $true -and $settings.last_update_check_utc) 'update check time recorded'
$result=& $powershell -NoProfile -ExecutionPolicy Bypass -Command ". (Join-Path '$portableCheck' 'Gui-Core.ps1');Save-AC8AppSettings '$portableCheck' ([ordered]@{auto_update_check=`$false;last_update_check_utc=''});Test-AC8UpdateCheckDue '$portableCheck'"
Assert-True ($result -eq 'False') 'automatic check switched off'
$checks++

# ---- launch diagnostics ----
. (Join-Path $template 'Install-Common.ps1')
$payload=Join-Path $fixture 'payload';$w64=Join-Path $fixture 'w64'
foreach($rel in 'dwmapi.dll','ue4ss\UE4SS.dll','ue4ss\Mods\AC8MouseAim\Scripts\ac8_mouse_aim_010.dll'){
 foreach($root in $payload,$w64){$file=Join-Path $root $rel;New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null;[IO.File]::WriteAllText($file,$rel)}
}
Assert-True (!@(Get-AC8MissingDeployedDlls $payload $w64).Count) 'deployed DLLs intact'
Remove-Item -LiteralPath (Join-Path $w64 'dwmapi.dll');[IO.File]::WriteAllText((Join-Path $w64 'ue4ss\UE4SS.dll'),'changed')
Assert-True ((@(Get-AC8MissingDeployedDlls $payload $w64) -join ',') -eq 'dwmapi.dll,ue4ss\UE4SS.dll') 'missing and changed DLLs'
$full=[pscustomobject]@{MissileEnhancement=$true};$none=[pscustomobject]@{MissileEnhancement=$false}
$log=Join-Path $fixture 'UE4SS.log'
Assert-True ((Get-AC8ReadinessDiagnosis $log $full @('dwmapi.dll')) -match '安全软件') 'blocked DLL diagnosis'
Assert-True ((Get-AC8ReadinessDiagnosis $log $full) -match 'UE4SS 没有启动') 'no log diagnosis'
[IO.File]::WriteAllText($log,"[Lua] [AC8MouseAim] Loaded. x`r`n[Lua] [AC8SourceInit] SOURCE_FAILED reason=engine-ready boom rollbackErrors=0`r`n")
Assert-True ((Get-AC8ReadinessDiagnosis $log $full) -match '导弹模块初始化失败（engine-ready boom') 'missile failure diagnosis'
[IO.File]::WriteAllText($log,"Starting mods`r`n")
Assert-True ((Get-AC8ReadinessDiagnosis $log $none @() $true) -match '附加 Mod') 'mouse module not loaded with extra mods'
[IO.File]::WriteAllText($log,"[Lua] [AC8MouseAim] Loaded. x`r`n[Lua] [AC8SourceInit] CANDIDATE loaded`r`n")
Assert-True ((Get-AC8ReadinessDiagnosis $log $full) -match '等待游戏数据') 'missile still waiting'
$stream=[IO.File]::Open($log,'Open','ReadWrite','Read');try{Assert-True ((Get-AC8ReadinessDiagnosis $log $none) -match '仍在加载') 'log held open by the game'}finally{$stream.Dispose()}
$checks++

# ---- setup program (IExpress, part of Windows): unpack only, never run the installer here ----
if(Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\iexpress.exe')){
 $setupOut=Join-Path $fixture 'setup';New-Item -ItemType Directory -Path $setupOut | Out-Null
 & (Join-Path $repo 'scripts\build-setup.ps1') -Zip $zip250 -OutDir $setupOut | Out-Null
 $exe=Join-Path $setupOut 'AC8-Integrated-Setup-v2.5.0.exe';$unpacked=Join-Path $fixture 'setup-unpacked'
 $bytes=[IO.File]::ReadAllBytes($exe);$text=[Text.Encoding]::ASCII.GetString($bytes)
 Assert-True ($text -match 'requestedExecutionLevel\s+level="asInvoker"') 'setup program must not ask for administrator rights'
 $process=Start-Process -FilePath $exe -ArgumentList @('/Q','/C',('"/T:'+$unpacked+'"')) -Wait -PassThru
 Assert-True ($process.ExitCode -eq 0) 'setup program unpack'
 foreach($pair in @(@('AC8-Integrated-v2.5.0-share.zip',$zip250),@('Install-App.ps1',(Join-Path $template 'app\Install-App.ps1')),@('App-Core.ps1',(Join-Path $template 'app\App-Core.ps1')),@('install.cmd',(Join-Path $template 'app\install.cmd')))){
  Assert-True ((Get-FileHash (Join-Path $unpacked $pair[0])).Hash -eq (Get-FileHash $pair[1]).Hash) ('setup program content '+$pair[0])
 }
 $checks++
}else{Write-Host 'SKIP setup program: IExpress is not available here.'}

$rsa.Dispose();$other.Dispose()
Remove-AC8Tree $fixture
Write-Host "PASS installed app: $checks groups (setup and data layout, mod mode, host status, portable import, signed updates with 8 refusals, rollback, offline/online repair, pruning and uninstall, registration, signing scripts, launcher update check, launch diagnostics, setup program)"
