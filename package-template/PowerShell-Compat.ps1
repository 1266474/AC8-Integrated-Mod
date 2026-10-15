# Resolve built-in modules from the running host, even with an empty inherited
# PSModulePath or disabled module auto-loading (including GUI runspaces).
foreach($ac8Module in @('Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility')){
 $ac8ModulePath=[IO.Path]::Combine($PSHOME,'Modules',$ac8Module,($ac8Module+'.psd1'))
 Import-Module -Name $ac8ModulePath -ErrorAction Stop
}
function Enter-AC8Operation([string]$GameRoot){
 $canonical=[IO.Path]::GetFullPath($GameRoot).TrimEnd('\','/').ToUpperInvariant()
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','')}finally{$sha.Dispose()}
 $mutex=New-Object Threading.Mutex($false,('Local\AC8IntegratedSession-'+$key))
 $owned=$false
 try{
  try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
  if(!$owned){
   $failure=New-Object InvalidOperationException('Another AC8 session is starting or cleaning up. Wait for it to finish.')
   $failure.Data['AC8Code']='SESSION_BUSY';throw $failure
  }
  return $mutex
 }catch{$mutex.Dispose();throw}
}
function Exit-AC8Operation($Mutex){if($Mutex){try{$Mutex.ReleaseMutex()}finally{$Mutex.Dispose()}}}
# Idempotent when imported through both Install-Common and Cleanup-Core.
if(!(Test-Path Function:\Get-AC8FileHash)){
 function Get-AC8FileHash {
  param([Parameter(Mandatory=$true)][string]$LiteralPath,[ValidateSet('SHA256')][string]$Algorithm='SHA256')
  $path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath)
  $stream=$null;$sha=$null
  try{
   $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
   $sha=[Security.Cryptography.SHA256]::Create()
   $digest=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')
   return [pscustomobject]@{Algorithm='SHA256';Hash=$digest;Path=$path}
  }finally{if($sha){$sha.Dispose()};if($stream){$stream.Dispose()}}
 }
}
# Installed app (2.5.0): <install>\versions\<version>\ is a complete package marked by app-version.json; user data
# (settings, sessions, backups, diagnostics, ue4ss-mods) is shared in <install>\data and Steam starts the fixed entry
# <install>\Start-AC8-From-Steam.cmd. Without the marker the package is portable and keeps its data in its own folder.
function Get-AC8AppInfo([string]$PackageRoot){
 $package=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/')
 $marker=[IO.Path]::Combine($package,'app-version.json')
 if(![IO.File]::Exists($marker)){return $null}
 $versions=[IO.Path]::GetDirectoryName($package);$install=$null;$version=$null
 if($versions){$install=[IO.Path]::GetDirectoryName($versions)}
 try{$version=[string]([IO.File]::ReadAllText($marker) | ConvertFrom-Json).version}catch{$version=$null}
 $data=if($install){[IO.Path]::Combine($install,'data')}else{$null}
 if(!$install -or !$version -or [IO.Path]::GetFileName($versions) -ne 'versions' -or [IO.Path]::GetFileName($package) -ne $version -or ![IO.Directory]::Exists($data)){
  $failure=New-Object InvalidOperationException("安装版目录结构不完整：$package")
  $failure.Data['AC8Code']='APP_LAYOUT';$failure.Data['AC8Hint']='请在开始菜单打开 AC8 Integrated，使用“检查并修复”；仍不能解决时重新运行安装程序（设置和记录不会丢失）。'
  throw $failure
 }
 return [pscustomobject]@{Version=$version;PackageRoot=$package;InstallRoot=$install;DataRoot=$data;SteamEntry=[IO.Path]::Combine($install,'Start-AC8-From-Steam.cmd')}
}
# Folder for user data. Idempotent: the data folder itself (no marker) maps to itself.
function Get-AC8DataRoot([string]$PackageRoot){
 $app=Get-AC8AppInfo $PackageRoot
 if($app){return $app.DataRoot}
 return [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/')
}
# The command Steam's launch option must start: fixed at the install root for the app, inside the package when portable.
function Get-AC8SteamEntry([string]$PackageRoot){
 $app=Get-AC8AppInfo $PackageRoot
 if($app){return $app.SteamEntry}
 return [IO.Path]::Combine([IO.Path]::GetFullPath($PackageRoot).TrimEnd('\','/'),'Start-AC8-From-Steam.cmd')
}
