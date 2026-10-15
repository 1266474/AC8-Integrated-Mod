# AC8 Integrated installed app (2.5.0): install, update, repair, rollback and uninstall.
#  <install>\Host.ps1, App-Core.ps1, Start-AC8-From-Steam.cmd  host files, copied from the newest installed version
#  <install>\app.json                                            {schema, current, previous, versions[]}
#  <install>\trust\update-key.xml                                public RSA key that signs update-manifest.json
#  <install>\versions\<version>\                                 complete packages, marked by app-version.json
#  <install>\data\                                               player data shared by all versions
# Loaded by Host.ps1, by Install-App.ps1 and by the launcher's update check. Game files are only touched through the
# installed package's own cleanup (Launch-Offline.ps1 -CleanupOnly).

function Stop-AC8App([string]$Code,[string]$Message,[string]$Hint=''){
 $failure=New-Object InvalidOperationException($Message)
 $failure.Data['AC8Code']=$Code;$failure.Data['AC8Hint']=$Hint
 throw $failure
}
function Get-AC8DefaultInstallRoot{return [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'),'Programs','AC8 Integrated')}
function Test-AC8AppVersionName([string]$Version){return [bool]($Version -match '^\d{1,4}\.\d{1,4}\.\d{1,4}(?:-(?:alpha|beta|rc)\.\d{1,4})?$')}
function Compare-AC8AppVersion([string]$A,[string]$B){
 # -1, 0 or 1; a prerelease (2.5.0-beta.1) sorts before its release.
 $x=$A.Split([char[]]'-',2);$y=$B.Split([char[]]'-',2)
 $c=([version]$x[0]).CompareTo([version]$y[0]);if($c -ne 0){return [Math]::Sign($c)}
 if($x.Count -eq 1 -and $y.Count -eq 1){return 0}
 if($x.Count -eq 1){return 1};if($y.Count -eq 1){return -1}
 $p=$x[1].Split('.');$q=$y[1].Split('.')
 $c=[string]::CompareOrdinal($p[0],$q[0]);if($c -ne 0){return [Math]::Sign($c)}
 return [Math]::Sign(([int]$p[1]).CompareTo([int]$q[1]))
}
function Get-AC8SortedVersions([string[]]$Versions){
 # Newest first.
 $list=New-Object Collections.Generic.List[string]
 foreach($v in $Versions){$i=0;while($i -lt $list.Count -and (Compare-AC8AppVersion $list[$i] $v) -gt 0){$i++};$list.Insert($i,$v)}
 return @($list)
}
function Get-AC8AppHash([string]$Path){
 $sha=[Security.Cryptography.SHA256]::Create();$stream=[IO.File]::OpenRead($Path)
 try{return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}
}
function Write-AC8AppFile([string]$Path,[byte[]]$Bytes){
 # Complete or not at all: write beside the target, then replace it.
 $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllBytes($temporary,$Bytes)
 try{
  if([IO.File]::Exists($Path)){[IO.File]::SetAttributes($Path,[IO.FileAttributes]::Normal);[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
  else{[IO.File]::Move($temporary,$Path)}
 }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Write-AC8AppJson([string]$Path,$Value){Write-AC8AppFile $Path ((New-Object Text.UTF8Encoding($false)).GetBytes((ConvertTo-Json -InputObject $Value -Depth 8)))}
function Copy-AC8AppFile([string]$Source,[string]$Destination){
 # Returns $true when the destination was missing or different.
 if([IO.File]::Exists($Destination) -and (Get-AC8AppHash $Destination) -eq (Get-AC8AppHash $Source)){return $false}
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))
 Write-AC8AppFile $Destination ([IO.File]::ReadAllBytes($Source))
 return $true
}
function Remove-AC8Tree([string]$Path){
 # Never follows directory links (Windows PowerShell 5.1 Remove-Item -Recurse does).
 if(![IO.Directory]::Exists($Path)){if([IO.File]::Exists($Path)){[IO.File]::SetAttributes($Path,[IO.FileAttributes]::Normal);[IO.File]::Delete($Path)};return}
 $item=New-Object IO.DirectoryInfo($Path)
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){[IO.Directory]::Delete($Path,$false);return}
 foreach($child in $item.GetFileSystemInfos()){
  if($child -is [IO.DirectoryInfo]){Remove-AC8Tree $child.FullName}
  else{$child.Attributes=[IO.FileAttributes]::Normal;$child.Delete()}
 }
 $item.Attributes=[IO.FileAttributes]::Directory;$item.Delete($false)
}
function Copy-AC8Tree([string]$Source,[string]$Destination){
 # Folder copy without filesystem links; existing files are kept.
 [void][IO.Directory]::CreateDirectory($Destination)
 foreach($child in (New-Object IO.DirectoryInfo($Source)).GetFileSystemInfos()){
  if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
  $target=[IO.Path]::Combine($Destination,$child.Name)
  if($child -is [IO.DirectoryInfo]){Copy-AC8Tree $child.FullName $target}
  elseif(![IO.File]::Exists($target)){[IO.File]::Copy($child.FullName,$target,$false)}
 }
}

# ---- state ----
function Read-AC8AppState([string]$InstallRoot){
 $path=[IO.Path]::Combine($InstallRoot,'app.json')
 if(![IO.File]::Exists($path)){return $null}
 $state=$null;try{$state=[IO.File]::ReadAllText($path) | ConvertFrom-Json}catch{$state=$null}
 if(!$state -or $state.schema -ne 1 -or !(Test-AC8AppVersionName ([string]$state.current))){
  Stop-AC8App 'APP_STATE' 'app.json 已损坏。' '请在开始菜单打开 AC8 Integrated 并使用“检查并修复”，设置和记录不会丢失。'
 }
 return $state
}
function Get-AC8InstalledVersions([string]$InstallRoot){
 # Version folders with their marker, newest first.
 $dir=[IO.Path]::Combine($InstallRoot,'versions')
 if(![IO.Directory]::Exists($dir)){return @()}
 $names=@(Get-ChildItem -LiteralPath $dir -Directory | Where-Object {(Test-AC8AppVersionName $_.Name) -and [IO.File]::Exists([IO.Path]::Combine($_.FullName,'app-version.json'))} | ForEach-Object {$_.Name})
 return @(Get-AC8SortedVersions $names)
}
function Set-AC8AppCurrent([string]$InstallRoot,[string]$Version,[string]$Source){
 $state=$null;try{$state=Read-AC8AppState $InstallRoot}catch{$state=$null}
 $previous=$null;$entries=@()
 if($state){
  $previous=if([string]$state.current -ne $Version){[string]$state.current}else{[string]$state.previous}
  $entries=@($state.versions | Where-Object {$_ -and [string]$_.version -ne $Version})
 }
 if($previous -and !(Test-AC8AppVersionName $previous)){$previous=$null}
 $entries+=[pscustomobject]@{version=$Version;installedUtc=[DateTime]::UtcNow.ToString('o');source=$Source}
 Write-AC8AppJson ([IO.Path]::Combine($InstallRoot,'app.json')) ([pscustomobject]@{schema=1;current=$Version;previous=$previous;versions=@($entries)})
}
function Get-AC8CurrentPackage([string]$InstallRoot){
 $state=Read-AC8AppState $InstallRoot
 if(!$state){Stop-AC8App 'APP_STATE' '找不到 app.json，安装不完整。' '请重新运行安装程序；设置和记录不会丢失。'}
 $package=[IO.Path]::Combine($InstallRoot,'versions',[string]$state.current)
 if(![IO.File]::Exists([IO.Path]::Combine($package,'app-version.json'))){Stop-AC8App 'APP_LAYOUT' ('当前版本 '+$state.current+' 的程序文件夹缺失。') '请在开始菜单打开 AC8 Integrated 并使用“检查并修复”。'}
 return $package
}
function Get-AC8AppBusyReason([string]$InstallRoot,[switch]$AllowSession){
 foreach($name in 'AceCombat8','start_protected_game','ac8_screen_input'){
  if(Get-Process -Name $name -ErrorAction SilentlyContinue){return '游戏仍在运行（'+$name+'）。请正常退出游戏，等启动控制台完成清理后再试。'}
 }
 if(!$AllowSession -and [IO.File]::Exists([IO.Path]::Combine($InstallRoot,'data','active-session.json'))){
  return '上一次游戏会话还没有清理完成。请先从 Steam 启动一次（会先自动清理），或运行“检查并修复”。'
 }
 return $null
}

# ---- packages ----
function Read-AC8FileList([string]$Path){
 # FILES.sha256 is UTF-8 (it names Chinese files); packages built before 2.5.0 used the builder's ANSI code page.
 $bytes=[IO.File]::ReadAllBytes($Path)
 try{$text=(New-Object Text.UTF8Encoding($false,$true)).GetString($bytes)}catch{$text=[Text.Encoding]::Default.GetString($bytes)}
 return @($text.TrimStart([char]0xFEFF) -split "`r?`n" | Where-Object {$_})
}
function Get-AC8PackageFileProblems([string]$PackageRoot,[string[]]$Skip=@()){
 # FILES.sha256 of the release package: missing or changed files (relative paths). Extra files are not reported.
 $root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/')
 $list=[IO.Path]::Combine($root,'FILES.sha256')
 if(![IO.File]::Exists($list)){return @('FILES.sha256')}
 $problems=New-Object Collections.Generic.List[string]
 foreach($line in (Read-AC8FileList $list)){
  if(!$line){continue}
  if($line -notmatch '^([0-9a-fA-F]{64})  (.+)$'){$problems.Add('FILES.sha256');break}
  $digest=$Matches[1].ToUpperInvariant();$rel=$Matches[2]
  if($Skip -contains $rel){continue}
  $file=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$rel.Replace('/','\')))
  if(!$file.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){$problems.Add($rel);continue}
  if(![IO.File]::Exists($file) -or (Get-AC8AppHash $file) -ne $digest){$problems.Add($rel)}
 }
 return @($problems)
}
function Expand-AC8PackageZip([string]$Zip,[string]$Destination){
 # Extract a release zip (one top folder) and verify it completely: every file listed in FILES.sha256 with its hash,
 # nothing unlisted, the installed-app host present.
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $dest=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
 [void][IO.Directory]::CreateDirectory($dest)
 $tops=@{};$archive=[IO.Compression.ZipFile]::OpenRead($Zip)
 try{
  foreach($entry in $archive.Entries){
   $name=$entry.FullName.Replace('/','\')
   if(!$name -or $name.StartsWith('\') -or $name.Contains(':') -or $name -match '(^|\\)\.\.(\\|$)'){Stop-AC8App 'PACKAGE_INVALID' '安装包含有不安全的路径，已拒绝。'}
   $target=[IO.Path]::GetFullPath([IO.Path]::Combine($dest,$name))
   if(!$target.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase)){Stop-AC8App 'PACKAGE_INVALID' '安装包含有不安全的路径，已拒绝。'}
   $tops[$name.Split('\')[0]]=$true
   if($name.EndsWith('\')){[void][IO.Directory]::CreateDirectory($target);continue}
   [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
  }
 }finally{$archive.Dispose()}
 if($tops.Count -ne 1){Stop-AC8App 'PACKAGE_INVALID' '安装包结构不正确。'}
 $package=[IO.Path]::Combine($dest,@($tops.Keys)[0])
 $problems=@(Get-AC8PackageFileProblems $package)
 if($problems.Count){Stop-AC8App 'PACKAGE_INVALID' ('安装包校验失败：'+$problems[0]) '请重新下载安装包。'}
 $listed=@{}
 foreach($line in (Read-AC8FileList ([IO.Path]::Combine($package,'FILES.sha256')))){$listed[$line.Substring(66).Replace('/','\')]=$true}
 foreach($file in [IO.Directory]::GetFiles($package,'*','AllDirectories')){
  $rel=$file.Substring($package.Length+1)
  if($rel -ne 'FILES.sha256' -and !$listed.ContainsKey($rel)){Stop-AC8App 'PACKAGE_INVALID' ('安装包含有未登记的文件：'+$rel) '请重新下载安装包。'}
 }
 $info=$null;try{$info=[IO.File]::ReadAllText([IO.Path]::Combine($package,'package-info.json')) | ConvertFrom-Json}catch{$info=$null}
 if(!$info -or !(Test-AC8AppVersionName ([string]$info.version))){Stop-AC8App 'PACKAGE_INVALID' '安装包缺少有效的版本信息。'}
 if(![IO.File]::Exists([IO.Path]::Combine($package,'app\Host.ps1'))){Stop-AC8App 'PACKAGE_INVALID' ('版本 '+$info.version+' 不支持安装版（需要 2.5.0 或更新）。')}
 return [pscustomobject]@{Path=$package;Version=[string]$info.version}
}
function Install-AC8AppVersion([string]$InstallRoot,[string]$Zip,[string]$ExpectedVersion=''){
 # versions\<version> from a release zip. The same version again (reinstall, repair) replaces only the files that
 # differ, in place, so files held open elsewhere in the folder do not block it.
 $versions=[IO.Path]::Combine($InstallRoot,'versions');[void][IO.Directory]::CreateDirectory($versions)
 $staging=[IO.Path]::Combine($versions,'.staging-'+[guid]::NewGuid().ToString('N'))
 try{
  $package=Expand-AC8PackageZip $Zip $staging
  if($ExpectedVersion -and $package.Version -ne $ExpectedVersion){Stop-AC8App 'PACKAGE_VERSION' ('安装包版本 '+$package.Version+' 与预期的 '+$ExpectedVersion+' 不一致，已拒绝。')}
  Write-AC8AppJson ([IO.Path]::Combine($package.Path,'app-version.json')) ([pscustomobject]@{schema=1;version=$package.Version})
  $target=[IO.Path]::Combine($versions,$package.Version)
  if(![IO.Directory]::Exists($target)){[IO.Directory]::Move($package.Path,$target)}
  else{
   foreach($file in [IO.Directory]::GetFiles($package.Path,'*','AllDirectories')){
    $null=Copy-AC8AppFile $file ([IO.Path]::Combine($target,$file.Substring($package.Path.Length+1)))
   }
  }
  $problems=@(Get-AC8PackageFileProblems $target)
  if($problems.Count){Stop-AC8App 'PACKAGE_WRITE' ('写入后校验失败：'+$problems[0]) '文件可能被安全软件拦截。请查看 Windows 安全中心的保护历史，恢复误拦截的文件后重试。'}
  return $package.Version
 }finally{if([IO.Directory]::Exists($staging)){Remove-AC8Tree $staging}}
}
function Save-AC8PackageCache([string]$InstallRoot,[string]$Version,[string]$Zip){
 # Keep the verified zip of an installed version for offline repair (about 10 MB).
 $dir=[IO.Path]::Combine($InstallRoot,'data','update-cache',$Version);[void][IO.Directory]::CreateDirectory($dir)
 $name=[IO.Path]::GetFileName($Zip);$target=[IO.Path]::Combine($dir,$name)
 if(![string]::Equals([IO.Path]::GetFullPath($Zip),$target,[StringComparison]::OrdinalIgnoreCase)){$null=Copy-AC8AppFile $Zip $target}
 Write-AC8AppJson ([IO.Path]::Combine($dir,'package.json')) ([pscustomobject]@{version=$Version;asset=$name;sha256=(Get-AC8AppHash $target)})
}
function Get-AC8PackageCache([string]$InstallRoot,[string]$Version){
 $dir=[IO.Path]::Combine($InstallRoot,'data','update-cache',$Version);$record=[IO.Path]::Combine($dir,'package.json')
 if(![IO.File]::Exists($record)){return $null}
 try{$info=[IO.File]::ReadAllText($record) | ConvertFrom-Json}catch{return $null}
 $zip=[IO.Path]::Combine($dir,[IO.Path]::GetFileName([string]$info.asset))
 if([string]$info.version -ne $Version -or ![IO.File]::Exists($zip) -or (Get-AC8AppHash $zip) -ne [string]$info.sha256){return $null}
 return $zip
}
function Install-AC8HostFiles([string]$InstallRoot,[string]$PackageRoot){
 $app=[IO.Path]::Combine($PackageRoot,'app');$changed=@()
 foreach($pair in @(@('Host.ps1','Host.ps1'),@('App-Core.ps1','App-Core.ps1'),@('Start-AC8-From-Steam.cmd','Start-AC8-From-Steam.cmd'),@('update-key.xml','trust\update-key.xml'))){
  if(Copy-AC8AppFile ([IO.Path]::Combine($app,$pair[0])) ([IO.Path]::Combine($InstallRoot,$pair[1]))){$changed+=$pair[1]}
 }
 return $changed
}
function Remove-AC8OldVersions([string]$InstallRoot){
 # Keep the current and the previous version (and their cached zips); remove older ones and interrupted staging.
 $state=Read-AC8AppState $InstallRoot;$keep=@([string]$state.current,[string]$state.previous) | Where-Object {$_}
 $versions=[IO.Path]::Combine($InstallRoot,'versions')
 if([IO.Directory]::Exists($versions)){
  foreach($dir in Get-ChildItem -LiteralPath $versions -Directory -Force){
   if($keep -contains $dir.Name){continue}
   try{Remove-AC8Tree $dir.FullName}catch{}
  }
 }
 $cache=[IO.Path]::Combine($InstallRoot,'data','update-cache')
 if([IO.Directory]::Exists($cache)){
  foreach($dir in Get-ChildItem -LiteralPath $cache -Directory -Force){
   if($keep -contains $dir.Name){continue}
   try{Remove-AC8Tree $dir.FullName}catch{}
  }
 }
}

# ---- player data ----
function Repair-AC8PlayerSettings([string]$DataRoot,[string]$PackageRoot){
 # Every settings file must be readable by this package. An unreadable one is backed up and rebuilt from the package
 # template, keeping each saved value the package still accepts. Then the one-time migrations run.
 . ([IO.Path]::Combine($PackageRoot,'MouseAim-Settings.ps1'))
 . ([IO.Path]::Combine($PackageRoot,'Feature-Settings.ps1'))
 . ([IO.Path]::Combine($PackageRoot,'Keybinding-Settings.ps1'))
 $report=@()
 $checks=@(
  @{Name='MouseAim-Settings.ini';Label='飞控设置';Read={param($p) $null=Read-MouseSettings $p}},
  @{Name='features.ini';Label='安装范围';Read={param($p) $null=Read-FeatureSettings $p}},
  @{Name='Keybindings.ini';Label='键位设置';Read={param($p) $null=Read-AC8Keybindings $p}}
 )
 foreach($check in $checks){
  $path=[IO.Path]::Combine($DataRoot,$check.Name);$template=[IO.Path]::Combine($PackageRoot,$check.Name)
  if(![IO.File]::Exists($path)){[IO.File]::Copy($template,$path);$report+=[pscustomobject]@{Item=$check.Label;Status='fixed';Message=($check.Name+' 缺失，已恢复默认。')};continue}
  $reason=$null;try{& $check.Read $path}catch{$reason=$_.Exception.Message}
  if(!$reason){$report+=[pscustomobject]@{Item=$check.Label;Status='ok';Message=($check.Name+' 正常。')};continue}
  $backup=[IO.Path]::Combine($DataRoot,'repair-backups',(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
  [void][IO.Directory]::CreateDirectory($backup);[IO.File]::Copy($path,[IO.Path]::Combine($backup,$check.Name))
  $templateBytes=[IO.File]::ReadAllBytes($template);$bom=$templateBytes.Length -ge 3 -and $templateBytes[0] -eq 0xEF -and $templateBytes[1] -eq 0xBB -and $templateBytes[2] -eq 0xBF
  $text=[IO.File]::ReadAllText($template);$saved=[ordered]@{};$kept=0
  foreach($line in [IO.File]::ReadAllLines($path)){if($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$'){$saved[$Matches[1]]=$Matches[2]}}
  $probe=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
  try{
   foreach($key in $saved.Keys){
    $pattern='(?m)^'+[regex]::Escape($key)+'=[^\r\n]*'
    if(![regex]::IsMatch($text,$pattern)){continue}
    $candidate=[regex]::Replace($text,$pattern,($key+'='+$saved[$key]).Replace('$','$$'))
    [IO.File]::WriteAllText($probe,$candidate,(New-Object Text.UTF8Encoding($bom)))
    $accepted=$true;try{& $check.Read $probe}catch{$accepted=$false}
    if($accepted){$text=$candidate;$kept++}
   }
  }finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
  Write-AC8AppFile $path ((New-Object Text.UTF8Encoding($bom)).GetBytes($text))
  $report+=[pscustomobject]@{Item=$check.Label;Status='fixed';Message=($check.Name+' 无法读取（'+$reason+'）。原文件已备份到 '+$backup+'，已恢复默认并保留 '+$kept+' 项可用设置。')}
 }
 if(Get-Command Invoke-AC8SettingsMigrations -ErrorAction SilentlyContinue){
  foreach($migration in @(Invoke-AC8SettingsMigrations $DataRoot)){
   if($migration -eq 'war-default-2.5.0'){$report+=[pscustomobject]@{Item='飞控设置';Status='fixed';Message='2.5.0 起默认飞控为 WAR，已将启动模式设为 WAR（游戏中 F4 可切回 PEACE）。'}}
  }
 }
 return $report
}
function Initialize-AC8AppData([string]$InstallRoot,[string]$PackageRoot,[string]$ImportFrom=''){
 # data\ for a new install (defaults or the settings of a portable package) and for every new version (new defaults,
 # migrations). Existing player files are never replaced here.
 $data=[IO.Path]::Combine($InstallRoot,'data');[void][IO.Directory]::CreateDirectory($data)
 $report=@()
 foreach($name in 'MouseAim-Settings.ini','Keybindings.ini','features.ini','game-path.txt','steam-path.txt'){
  $target=[IO.Path]::Combine($data,$name);if([IO.File]::Exists($target)){continue}
  $source=[IO.Path]::Combine($PackageRoot,$name)
  if($ImportFrom){$old=[IO.Path]::Combine($ImportFrom,$name);if([IO.File]::Exists($old)){$source=$old;$report+=[pscustomobject]@{Item='导入';Status='fixed';Message=('已导入 '+$name)}}}
  [IO.File]::Copy($source,$target)
 }
 $mods=[IO.Path]::Combine($data,'ue4ss-mods');[void][IO.Directory]::CreateDirectory($mods)
 $readme=[IO.Path]::Combine($PackageRoot,'ue4ss-mods','README.txt')
 if([IO.File]::Exists($readme)){$null=Copy-AC8AppFile $readme ([IO.Path]::Combine($mods,'README.txt'))}
 if($ImportFrom){
  $oldMods=[IO.Path]::Combine($ImportFrom,'ue4ss-mods')
  if([IO.Directory]::Exists($oldMods)){
   foreach($dir in Get-ChildItem -LiteralPath $oldMods -Directory -Force){
    if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
    $target=[IO.Path]::Combine($mods,$dir.Name)
    if(![IO.Directory]::Exists($target)){Copy-AC8Tree $dir.FullName $target;$report+=[pscustomobject]@{Item='导入';Status='fixed';Message=('已导入附加 Mod '+$dir.Name)}}
   }
  }
 }
 $option='"'+[IO.Path]::Combine($InstallRoot,'Start-AC8-From-Steam.cmd')+'" %command%'
 Set-Content -LiteralPath ([IO.Path]::Combine($data,'Steam-Launch-Option.txt')) -Value $option -Encoding UTF8
 $report+=@(Repair-AC8PlayerSettings $data $PackageRoot | Where-Object {$_.Status -ne 'ok'})
 return $report
}
function Find-AC8PortablePackage([string]$InstallRoot,[string]$SteamRoot=''){
 # The portable package the current Steam launch option starts (read-only: Steam's own settings are not changed).
 # Also resolves the managed-package folder layout. Returns $null when none is found.
 $steamRoot=$SteamRoot
 if(!$steamRoot){try{$steamRoot=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath}catch{$steamRoot=$null}}
 if(!$steamRoot){return $null}
 $steamRoot=$steamRoot.Replace('/','\')
 $found=@()
 foreach($user in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($steamRoot,'userdata')) -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^\d+$' -and $_.Name -ne '0'})){
  $file=[IO.Path]::Combine($user.FullName,'config','localconfig.vdf')
  if(![IO.File]::Exists($file)){continue}
  $text=[IO.File]::ReadAllText($file)
  $match=[regex]::Match($text,'"2288340"\s*\{');if(!$match.Success){continue}
  $start=$match.Index+$match.Length;$i=$start;$depth=1;$quoted=$false;$escape=$false
  while($i -lt $text.Length -and $depth -gt 0){
   $c=$text[$i]
   if($escape){$escape=$false}elseif($quoted -and $c -eq '\'){$escape=$true}elseif($c -eq '"'){$quoted=!$quoted}
   elseif(!$quoted -and $c -eq '{'){$depth++}elseif(!$quoted -and $c -eq '}'){$depth--}
   $i++
  }
  if($depth){continue}
  $option=[regex]::Match($text.Substring($start,$i-$start-1),'"LaunchOptions"\s*"((?:\\.|[^"\\])*)"')
  if(!$option.Success){continue}
  $value=[regex]::Replace($option.Groups[1].Value,'\\([\\"])','$1')
  $entry=[regex]::Match($value,'^\s*"([^"]+)\\Start-AC8-From-Steam\.cmd"\s+%command%\s*$')
  if($entry.Success){$found+=$entry.Groups[1].Value}
 }
 foreach($folder in @($found | Select-Object -Unique)){
  $candidate=$folder
  $registry=[IO.Path]::Combine($folder,'AC8-Managed-Packages.json')
  if([IO.File]::Exists($registry)){
   try{$active=[string]([IO.File]::ReadAllText($registry) | ConvertFrom-Json).activePackage}catch{$active=''}
   if($active -notmatch '^[A-Za-z0-9._-]+$'){continue}
   $candidate=[IO.Path]::Combine($folder,$active)
  }
  if($InstallRoot -and [IO.Path]::GetFullPath($candidate).StartsWith([IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){continue}
  if([IO.File]::Exists([IO.Path]::Combine($candidate,'MouseAim-Settings.ini')) -and [IO.File]::Exists([IO.Path]::Combine($candidate,'Launch-Offline.ps1')) -and ![IO.File]::Exists([IO.Path]::Combine($candidate,'app-version.json'))){return $candidate}
 }
 return $null
}

# ---- registration (Start menu, Apps & features) ----
function Get-AC8AppShortcutPath{return [IO.Path]::Combine([Environment]::GetFolderPath('Programs'),'AC8 Integrated.lnk')}
function Register-AC8App([string]$InstallRoot,[string]$Version,[string]$UninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AC8Integrated',[string]$Shortcut=(Get-AC8AppShortcutPath)){
 $powershell=[IO.Path]::Combine($PSHOME,'powershell.exe');$hostScript=[IO.Path]::Combine($InstallRoot,'Host.ps1')
 $icon=[IO.Path]::Combine($InstallRoot,'versions',$Version,'app','AC8.ico')
 $shell=New-Object -ComObject WScript.Shell
 try{
  $link=$shell.CreateShortcut($Shortcut)
  $link.TargetPath=$powershell
  $link.Arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$hostScript+'" -Action Gui'
  $link.WorkingDirectory=$InstallRoot;$link.Description='AC8 Integrated 启动器（离线单人）'
  if([IO.File]::Exists($icon)){$link.IconLocation=$icon+',0'}
  $link.Save()
 }finally{[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
 if(!(Test-Path -LiteralPath $UninstallKey)){New-Item -Path $UninstallKey -Force | Out-Null}
 $size=0;foreach($file in [IO.Directory]::GetFiles([IO.Path]::Combine($InstallRoot,'versions'),'*','AllDirectories')){$size+=(New-Object IO.FileInfo($file)).Length}
 $values=[ordered]@{DisplayName='AC8 Integrated';DisplayVersion=$Version;Publisher='CreeperUX';InstallLocation=$InstallRoot
  UninstallString=('"'+$powershell+'" -NoProfile -ExecutionPolicy Bypass -File "'+$hostScript+'" -Action Uninstall')
  URLInfoAbout='https://github.com/CreeperUX/AC8-Integrated-Mod';HelpLink='https://github.com/CreeperUX/AC8-Integrated-Mod/issues'}
 if([IO.File]::Exists($icon)){$values['DisplayIcon']=$icon}
 foreach($name in $values.Keys){Set-ItemProperty -LiteralPath $UninstallKey -Name $name -Value $values[$name]}
 foreach($name in 'NoModify','NoRepair'){New-ItemProperty -LiteralPath $UninstallKey -Name $name -Value 1 -PropertyType DWord -Force | Out-Null}
 New-ItemProperty -LiteralPath $UninstallKey -Name 'EstimatedSize' -Value ([int][Math]::Ceiling($size/1KB)) -PropertyType DWord -Force | Out-Null
}
function Unregister-AC8App([string]$UninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AC8Integrated',[string]$Shortcut=(Get-AC8AppShortcutPath)){
 if([IO.File]::Exists($Shortcut)){[IO.File]::Delete($Shortcut)}
 if(Test-Path -LiteralPath $UninstallKey){Remove-Item -LiteralPath $UninstallKey -Recurse -Force}
}
function Test-AC8AppRegistered([string]$InstallRoot,[string]$UninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AC8Integrated',[string]$Shortcut=(Get-AC8AppShortcutPath)){
 if(![IO.File]::Exists($Shortcut) -or !(Test-Path -LiteralPath $UninstallKey)){return $false}
 $location=(Get-ItemProperty -LiteralPath $UninstallKey -ErrorAction SilentlyContinue).InstallLocation
 return [string]::Equals([string]$location,$InstallRoot,[StringComparison]::OrdinalIgnoreCase)
}

# ---- updates (GitHub releases, signed manifest) ----
function Get-AC8ReleaseInfo([string]$Feed='',[string]$Tag=''){
 # Latest stable release, or the release of one tag (repair). $Feed: a local folder with release.json and the assets
 # (tests); the manifest signature is checked the same way.
 if($Feed){
  $name=if($Tag){'release-'+$Tag+'.json'}else{'release.json'}
  return [IO.File]::ReadAllText([IO.Path]::Combine($Feed,$name)) | ConvertFrom-Json
 }
 [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
 $uri='https://api.github.com/repos/CreeperUX/AC8-Integrated-Mod/releases/'+$(if($Tag){'tags/'+[Uri]::EscapeDataString($Tag)}else{'latest'})
 try{return Invoke-RestMethod -Uri $uri -Headers @{'User-Agent'='AC8-Integrated-Updater';'Accept'='application/vnd.github+json'} -TimeoutSec 30 -UseBasicParsing}
 catch{Stop-AC8App 'UPDATE_NETWORK' ('无法连接 GitHub：'+$_.Exception.Message) '请检查网络后重试。只访问 GitHub 发布页，不上传任何数据。'}
}
function Save-AC8ReleaseAsset($Release,[string]$Name,[string]$Destination,[string]$Feed='',[long]$MaxBytes=262144){
 $asset=@($Release.assets | Where-Object {[string]$_.name -ceq $Name})
 if($asset.Count -ne 1){Stop-AC8App 'UPDATE_ASSET' ('发布中缺少 '+$Name+'。') '这个版本可能不支持自动更新，请到 GitHub 发布页手动下载。'}
 if([long]$asset[0].size -gt $MaxBytes){Stop-AC8App 'UPDATE_ASSET' ($Name+' 大小异常，已拒绝。')}
 if($Feed){[IO.File]::Copy([IO.Path]::Combine($Feed,$Name),$Destination,$true)}
 else{
  $url=[string]$asset[0].browser_download_url
  if(!$url.StartsWith('https://github.com/CreeperUX/AC8-Integrated-Mod/releases/download/',[StringComparison]::Ordinal)){Stop-AC8App 'UPDATE_SOURCE' '下载地址不是本项目的 GitHub 发布，已拒绝。'}
  $ProgressPreference='SilentlyContinue'
  try{Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 600 -Headers @{'User-Agent'='AC8-Integrated-Updater'}}
  catch{Stop-AC8App 'UPDATE_NETWORK' ('下载 '+$Name+' 失败：'+$_.Exception.Message) '请检查网络后重试。'}
 }
 if((New-Object IO.FileInfo($Destination)).Length -ne [long]$asset[0].size){Stop-AC8App 'UPDATE_ASSET' ($Name+' 下载不完整。') '请重试。'}
}
function Test-AC8UpdateSignature([byte[]]$Data,[string]$Signature,[string]$KeyPath){
 # RSA-SHA256 (PKCS#1 v1.5) over the exact manifest bytes with the public key of this installation.
 if(![IO.File]::Exists($KeyPath)){return $false}
 $xml=[IO.File]::ReadAllText($KeyPath)
 if($xml -match '<(D|P|Q|DP|DQ|InverseQ)>'){Stop-AC8App 'UPDATE_KEY' '更新公钥文件含有私钥内容，已拒绝。'}
 $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider;$rsa.PersistKeyInCsp=$false
 try{
  $rsa.FromXmlString($xml);if($rsa.KeySize -lt 3072){return $false}
  $bytes=$null;try{$bytes=[Convert]::FromBase64String($Signature.Trim())}catch{return $false}
  return $rsa.VerifyData($Data,'SHA256',$bytes)
 }finally{$rsa.Dispose()}
}
function Get-AC8UpdateOffer([string]$InstallRoot,[string]$Feed='',[string]$Tag=''){
 # Release info plus its signed update manifest, verified. Does not download the package.
 $release=Get-AC8ReleaseInfo $Feed $Tag
 $tagName=[string]$release.tag_name
 if($tagName -notmatch '^v(.+)$' -or !(Test-AC8AppVersionName $Matches[1])){Stop-AC8App 'UPDATE_MANIFEST' ('发布标签 '+$tagName+' 无法识别。')}
 $version=$Matches[1]
 $cache=[IO.Path]::Combine($InstallRoot,'data','update-cache','incoming-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($cache)
 $manifestPath=[IO.Path]::Combine($cache,'update-manifest.json');$signaturePath=$manifestPath+'.sig'
 Save-AC8ReleaseAsset $release 'update-manifest.json' $manifestPath $Feed
 Save-AC8ReleaseAsset $release 'update-manifest.json.sig' $signaturePath $Feed
 $bytes=[IO.File]::ReadAllBytes($manifestPath)
 if(!(Test-AC8UpdateSignature $bytes ([IO.File]::ReadAllText($signaturePath)) ([IO.Path]::Combine($InstallRoot,'trust','update-key.xml')))){
  Stop-AC8App 'UPDATE_SIGNATURE' '更新清单的签名无效，已拒绝。' '请稍后重试；如果持续出现，请到 GitHub 发布页手动下载安装程序。'
 }
 $manifest=(New-Object Text.UTF8Encoding($false)).GetString($bytes) | ConvertFrom-Json
 $asset='AC8-Integrated-v'+$version+'-share.zip'
 if($manifest.schema -ne 1 -or [string]$manifest.product -ne 'AC8-Integrated' -or [string]$manifest.version -ne $version -or [string]$manifest.asset -ne $asset -or [string]$manifest.sha256 -notmatch '^[0-9A-Fa-f]{64}$' -or [long]$manifest.size -le 0){
  Stop-AC8App 'UPDATE_MANIFEST' '更新清单与发布不一致，已拒绝。'
 }
 return [pscustomobject]@{Version=$version;Tag=$tagName;Manifest=$manifest;Release=$release;Cache=$cache;NotesUrl=[string]$release.html_url}
}
function Save-AC8UpdatePackage([string]$InstallRoot,$Offer,[string]$Feed=''){
 $zip=[IO.Path]::Combine($Offer.Cache,[string]$Offer.Manifest.asset)
 Save-AC8ReleaseAsset $Offer.Release ([string]$Offer.Manifest.asset) $zip $Feed ([long]$Offer.Manifest.size)
 if((New-Object IO.FileInfo($zip)).Length -ne [long]$Offer.Manifest.size -or (Get-AC8AppHash $zip) -ne ([string]$Offer.Manifest.sha256).ToUpperInvariant()){
  Stop-AC8App 'UPDATE_HASH' '下载的安装包与签名清单不符，已拒绝。' '请重试；网络或代理可能改动了文件。'
 }
 return $zip
}
function Complete-AC8AppInstall([string]$InstallRoot,[string]$Version,[string]$Source,[string]$Zip,[string]$ImportFrom='',[switch]$NoRegister){
 # After versions\<version> is in place: player data, cached zip, app.json switch, host files, registration, cleanup.
 $package=[IO.Path]::Combine($InstallRoot,'versions',$Version)
 $report=@(Initialize-AC8AppData $InstallRoot $package $ImportFrom)
 Save-AC8PackageCache $InstallRoot $Version $Zip
 Set-AC8AppCurrent $InstallRoot $Version $Source
 $null=Install-AC8HostFiles $InstallRoot $package
 if(!$NoRegister){Register-AC8App $InstallRoot $Version}
 Remove-AC8OldVersions $InstallRoot
 foreach($dir in @(Get-ChildItem -LiteralPath ([IO.Path]::Combine($InstallRoot,'data','update-cache')) -Directory -Filter 'incoming-*' -ErrorAction SilentlyContinue)){try{Remove-AC8Tree $dir.FullName}catch{}}
 return $report
}
function Install-AC8AppUpdate([string]$InstallRoot,$Offer,[string]$Feed='',[switch]$NoRegister){
 $busy=Get-AC8AppBusyReason $InstallRoot;if($busy){Stop-AC8App 'APP_BUSY' $busy}
 $state=Read-AC8AppState $InstallRoot
 if((Compare-AC8AppVersion $Offer.Version ([string]$state.current)) -le 0){Stop-AC8App 'UPDATE_NOT_NEWER' ('已是最新版本 '+$state.current+'。')}
 $zip=Save-AC8UpdatePackage $InstallRoot $Offer $Feed
 $version=Install-AC8AppVersion $InstallRoot $zip $Offer.Version
 return @(Complete-AC8AppInstall $InstallRoot $version 'update' $zip -NoRegister:$NoRegister)
}

# ---- repair, rollback, uninstall ----
function Invoke-AC8AppRepair{
 # Findings: Item, Status (ok / fixed / problem), Message. -Quick (before every launch): app.json, version files and host
 # files only, repaired from the cached verified zip. The full check adds a download of the same version when needed,
 # player settings, an unfinished session, loader leftovers, the Steam launch option and the registration.
 param([string]$InstallRoot,[string]$Feed='',[switch]$Offline,[switch]$Quick,[switch]$NoRegister)
 $findings=New-Object Collections.ArrayList # (List[object] of PSObjects cannot be unrolled by @() in Windows PowerShell 5.1)
 $state=$null;try{$state=Read-AC8AppState $InstallRoot}catch{$state=$null}
 $installed=@(Get-AC8InstalledVersions $InstallRoot)
 if(!$state -or $installed -notcontains [string]$state.current){
  if(!$installed.Count){[void]$findings.Add([pscustomobject]@{Item='版本';Status='problem';Message='没有找到已安装的版本，请重新运行安装程序（设置和记录不会丢失）。'});return @($findings)}
  $previous=if($installed.Count -gt 1){$installed[1]}else{$null}
  Write-AC8AppJson ([IO.Path]::Combine($InstallRoot,'app.json')) ([pscustomobject]@{schema=1;current=$installed[0];previous=$previous;versions=@()})
  [void]$findings.Add([pscustomobject]@{Item='版本记录';Status='fixed';Message=('app.json 缺失或损坏，已按已安装版本重建，当前版本 '+$installed[0]+'。')})
  $state=Read-AC8AppState $InstallRoot
 }
 $current=[string]$state.current;$package=[IO.Path]::Combine($InstallRoot,'versions',$current)
 $problems=@(Get-AC8PackageFileProblems $package)
 if($problems.Count){
  $restored=$false;$why=''
  $cached=Get-AC8PackageCache $InstallRoot $current
  if($cached){try{$null=Install-AC8AppVersion $InstallRoot $cached $current;$restored=$true}catch{$why=$_.Exception.Message}}
  if(!$restored -and !$Offline -and !$Quick){
   try{
    $offer=Get-AC8UpdateOffer $InstallRoot $Feed ('v'+$current)
    if($offer.Version -ne $current){Stop-AC8App 'UPDATE_MANIFEST' '发布版本与当前版本不一致。'}
    $zip=Save-AC8UpdatePackage $InstallRoot $offer $Feed
    $null=Install-AC8AppVersion $InstallRoot $zip $current;Save-AC8PackageCache $InstallRoot $current $zip;$restored=$true
   }catch{$why=$_.Exception.Message}
  }
  $sample=$problems[0]+$(if($problems.Count -gt 1){' 等 '+$problems.Count+' 个文件'}else{''})
  if($restored){[void]$findings.Add([pscustomobject]@{Item='程序文件';Status='fixed';Message=('版本 '+$current+' 的 '+$sample+' 缺失或被改动，已从校验过的安装包恢复。')})}
  else{[void]$findings.Add([pscustomobject]@{Item='程序文件';Status='problem';Message=('版本 '+$current+' 的 '+$sample+' 缺失或被改动，无法自动恢复'+$(if($why){'：'+$why}else{'（需要联网下载同一版本）'})+'。')})}
 }else{[void]$findings.Add([pscustomobject]@{Item='程序文件';Status='ok';Message=('版本 '+$current+' 的程序文件完整。')})}
 # Host files follow the newest installed version that is intact.
 $hostSource=$null
 foreach($version in $installed){$candidate=[IO.Path]::Combine($InstallRoot,'versions',$version);if(!@(Get-AC8PackageFileProblems $candidate).Count){$hostSource=$candidate;break}}
 if($hostSource){
  $changed=@(Install-AC8HostFiles $InstallRoot $hostSource)
  if($changed.Count){[void]$findings.Add([pscustomobject]@{Item='启动入口';Status='fixed';Message=('已恢复 '+($changed -join '、')+'。')})}
 }
 if($Quick){return @($findings)}
 $data=[IO.Path]::Combine($InstallRoot,'data')
 if(!@($findings | Where-Object {$_.Item -eq '程序文件' -and $_.Status -eq 'problem'}).Count){
  foreach($item in @(Repair-AC8PlayerSettings $data $package)){[void]$findings.Add($item)}
  $session=[IO.Path]::Combine($data,'active-session.json')
  if([IO.File]::Exists($session)){
   $busy=Get-AC8AppBusyReason $InstallRoot -AllowSession
   if($busy){[void]$findings.Add([pscustomobject]@{Item='游戏会话';Status='problem';Message=$busy})}
   else{
    $output=@(& ([IO.Path]::Combine($PSHOME,'powershell.exe')) -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($package,'Launch-Offline.ps1')) -CleanupOnly 2>&1 | ForEach-Object {[string]$_})
    if($LASTEXITCODE -eq 0 -and ![IO.File]::Exists($session)){[void]$findings.Add([pscustomobject]@{Item='游戏会话';Status='fixed';Message='上一次未完成的会话已清理，游戏目录已恢复原版。'})}
    else{[void]$findings.Add([pscustomobject]@{Item='游戏会话';Status='problem';Message=('未完成的会话清理失败：'+(($output | Select-Object -Last 3) -join ' '))})}
   }
  }
  $gamePath=[IO.Path]::Combine($data,'game-path.txt');$game=''
  if([IO.File]::Exists($gamePath)){$game=([IO.File]::ReadAllText($gamePath)).Trim().Trim([char]0xFEFF)}
  if($game -and [IO.Directory]::Exists($game) -and ![IO.File]::Exists($session)){
   $w64=[IO.Path]::Combine($game,'Game','Binaries','Win64')
   $left=@('dwmapi.dll','ue4ss','steam_appid.txt' | Where-Object {Test-Path -LiteralPath ([IO.Path]::Combine($w64,$_))})
   if($left.Count){[void]$findings.Add([pscustomobject]@{Item='游戏目录';Status='problem';Message=('游戏目录有加载器文件：'+($left -join '、')+'。确认来自本整合包后，在启动器“维护与恢复”中点击“备份并清理”。')})}
   else{[void]$findings.Add([pscustomobject]@{Item='游戏目录';Status='ok';Message='游戏目录没有加载器残留。'})}
  }
  $steamPath=[IO.Path]::Combine($data,'steam-path.txt')
  if($game -and [IO.File]::Exists($steamPath) -and ([IO.File]::ReadAllText($steamPath)).Trim().Trim([char]0xFEFF)){
   $output=@(& ([IO.Path]::Combine($PSHOME,'powershell.exe')) -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($package,'Launch-AC8-via-Steam.ps1')) -CheckOnly 2>&1 | ForEach-Object {[string]$_})
   $option='"'+[IO.Path]::Combine($InstallRoot,'Start-AC8-From-Steam.cmd')+'" %command%'
   if($LASTEXITCODE -eq 0){[void]$findings.Add([pscustomobject]@{Item='Steam 启动选项';Status='ok';Message='Steam 启动选项指向安装版入口。'})}
   elseif($LASTEXITCODE -eq 2){[void]$findings.Add([pscustomobject]@{Item='Steam 启动选项';Status='problem';Message=('Steam 启动选项还不是安装版入口。请在 Steam → AC8 → 属性 → 通用 → 启动选项中粘贴：'+$option)})}
   else{[void]$findings.Add([pscustomobject]@{Item='Steam 启动选项';Status='problem';Message=('无法核对 Steam 启动选项：'+(($output | Select-Object -Last 2) -join ' '))})}
  }else{[void]$findings.Add([pscustomobject]@{Item='设置';Status='problem';Message='尚未保存游戏和 Steam 路径。请打开启动器，自动定位后点击“保存设置”。'})}
 }
 if(!$NoRegister -and !(Test-AC8AppRegistered $InstallRoot)){
  Register-AC8App $InstallRoot $current
  [void]$findings.Add([pscustomobject]@{Item='开始菜单与卸载项';Status='fixed';Message='已恢复开始菜单快捷方式和“应用”中的卸载项。'})
 }
 try{Remove-AC8OldVersions $InstallRoot}catch{}
 return @($findings)
}
function Invoke-AC8AppRollback([string]$InstallRoot,[switch]$NoRegister){
 $busy=Get-AC8AppBusyReason $InstallRoot;if($busy){Stop-AC8App 'APP_BUSY' $busy}
 $state=Read-AC8AppState $InstallRoot
 $previous=[string]$state.previous
 if(!$previous -or ![IO.File]::Exists([IO.Path]::Combine($InstallRoot,'versions',$previous,'app-version.json'))){Stop-AC8App 'NO_PREVIOUS' '没有可以回退的上一版本。'}
 $package=[IO.Path]::Combine($InstallRoot,'versions',$previous)
 $problems=@(Get-AC8PackageFileProblems $package)
 if($problems.Count){
  $cached=Get-AC8PackageCache $InstallRoot $previous
  if(!$cached){Stop-AC8App 'PREVIOUS_DAMAGED' ('上一版本 '+$previous+' 的文件不完整，无法回退。')}
  $null=Install-AC8AppVersion $InstallRoot $cached $previous
 }
 # Settings written by the newer version may contain keys the older one does not know.
 $report=@(Repair-AC8PlayerSettings ([IO.Path]::Combine($InstallRoot,'data')) $package | Where-Object {$_.Status -ne 'ok'})
 $entries=@($state.versions)
 Write-AC8AppJson ([IO.Path]::Combine($InstallRoot,'app.json')) ([pscustomobject]@{schema=1;current=$previous;previous=[string]$state.current;versions=$entries})
 if(!$NoRegister -and (Test-AC8AppRegistered $InstallRoot)){Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AC8Integrated' -Name DisplayVersion -Value $previous}
 return $report
}
function Invoke-AC8AppUninstall([string]$InstallRoot,[bool]$KeepData=$true,[switch]$NoRegister){
 # Game folder first: an unfinished session is cleaned with the installed package; loader files that cannot be
 # attributed stop the uninstall. Only the app's own entries are removed; the folder itself only when empty.
 if(![IO.File]::Exists([IO.Path]::Combine($InstallRoot,'app.json')) -or ![IO.Directory]::Exists([IO.Path]::Combine($InstallRoot,'versions'))){Stop-AC8App 'APP_LAYOUT' ('这里不是 AC8 Integrated 的安装目录：'+$InstallRoot)}
 $busy=Get-AC8AppBusyReason $InstallRoot -AllowSession;if($busy){Stop-AC8App 'APP_BUSY' $busy}
 $data=[IO.Path]::Combine($InstallRoot,'data');$session=[IO.Path]::Combine($data,'active-session.json')
 $package=$null;try{$package=Get-AC8CurrentPackage $InstallRoot}catch{$package=$null}
 if([IO.File]::Exists($session)){
  if(!$package){Stop-AC8App 'CLEANUP_REQUIRED' '有未完成的游戏会话，但当前版本文件不完整，无法清理。' '请先运行“检查并修复”，再卸载。'}
  & ([IO.Path]::Combine($PSHOME,'powershell.exe')) -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($package,'Launch-Offline.ps1')) -CleanupOnly
  if($LASTEXITCODE -ne 0 -or [IO.File]::Exists($session)){Stop-AC8App 'CLEANUP_REQUIRED' '未完成的游戏会话清理失败，已停止卸载。' '请查看上面的提示，处理后重试。'}
 }
 $gamePath=[IO.Path]::Combine($data,'game-path.txt')
 if([IO.File]::Exists($gamePath)){
  $game=([IO.File]::ReadAllText($gamePath)).Trim().Trim([char]0xFEFF)
  if($game -and [IO.Directory]::Exists($game)){
   $w64=[IO.Path]::Combine($game,'Game','Binaries','Win64')
   $left=@('dwmapi.dll','ue4ss','steam_appid.txt' | Where-Object {Test-Path -LiteralPath ([IO.Path]::Combine($w64,$_))})
   if($left.Count){Stop-AC8App 'LOADER_PRESENT' ('游戏目录仍有加载器文件：'+($left -join '、')+'，已停止卸载。') '确认来自本整合包后，先在启动器“维护与恢复”中点击“备份并清理”，再卸载。'}
  }
 }
 if(!$NoRegister){Unregister-AC8App}
 foreach($name in 'versions','trust'){Remove-AC8Tree ([IO.Path]::Combine($InstallRoot,$name))}
 foreach($name in 'Host.ps1','App-Core.ps1','Start-AC8-From-Steam.cmd','app.json'){Remove-AC8Tree ([IO.Path]::Combine($InstallRoot,$name))}
 if(!$KeepData){Remove-AC8Tree $data}
 if([IO.Directory]::Exists($InstallRoot) -and !@([IO.Directory]::GetFileSystemEntries($InstallRoot)).Count){[IO.Directory]::Delete($InstallRoot,$false)}
}
