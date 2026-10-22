# Managing the player's extra UE4SS mods (2.5.0): add from a zip or a folder, enable/disable, remove to a backup.
# Works only in the player data folder: ue4ss-mods (what loads), ue4ss-mods-removed (backups of removed or replaced mods)
# and ue4ss-mods-staging (temporary). The game folder is never touched; deployment stays with Launch-Offline.ps1.
. (Join-Path $PSScriptRoot 'Feature-Settings.ps1')

function Get-AC8ModTreeLinks([string]$Path) {
 # Filesystem links anywhere below $Path (they are never followed, copied or accepted).
 $link=[IO.FileAttributes]::ReparsePoint
 if((Get-Item -LiteralPath $Path -Force).Attributes -band $link){return @($Path)}
 return @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object {$_.Attributes -band $link} | ForEach-Object {$_.FullName})
}
function Test-AC8ModSkippedFile([string]$Name) {
 # Never installed with a mod: the UE4SS loader itself (this package brings its own). Pak/IoStore files inside a mod
 # folder belong to that mod (PW-MkI: AC8OverrideLoader\payloads mounts them itself) and are installed with it (2.5.2).
 return ($Name -in @('dwmapi.dll','UE4SS.dll','UE4SS-settings.ini','xinput1_3.dll'))
}
function Copy-AC8ModTree([string]$Source,[string]$Destination) {
 [void][IO.Directory]::CreateDirectory($Destination)
 foreach($child in (New-Object IO.DirectoryInfo($Source)).GetFileSystemInfos()){
  if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Filesystem link in the mod: $($child.FullName)"}
  if($child -isnot [IO.DirectoryInfo] -and (Test-AC8ModSkippedFile $child.Name)){continue}
  $target=[IO.Path]::Combine($Destination,$child.Name)
  if($child -is [IO.DirectoryInfo]){Copy-AC8ModTree $child.FullName $target}else{[IO.File]::Copy($child.FullName,$target,$false)}
 }
}
function Expand-AC8ModArchive([string]$Zip,[string]$Destination) {
 # Zip only (System.IO.Compression). Entries must stay inside the destination; size and count are bounded.
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $dest=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/');[void][IO.Directory]::CreateDirectory($dest)
 $archive=[IO.Compression.ZipFile]::OpenRead($Zip)
 try{
  if($archive.Entries.Count -gt 50000){throw '压缩包里的文件太多（超过 50000 个）。'}
  $total=0L;foreach($entry in $archive.Entries){$total+=$entry.Length}
  if($total -gt 2GB){throw '压缩包解压后超过 2 GB，不像是 UE4SS Mod。'}
  foreach($entry in $archive.Entries){
   $name=$entry.FullName.Replace('/','\')
   if(!$name -or $name.StartsWith('\') -or $name.Contains(':') -or $name -match '(^|\\)\.\.(\\|$)'){throw '压缩包含有不安全的路径，已拒绝。'}
   $target=[IO.Path]::GetFullPath([IO.Path]::Combine($dest,$name))
   if(!$target.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase)){throw '压缩包含有不安全的路径，已拒绝。'}
   if($name.EndsWith('\')){[void][IO.Directory]::CreateDirectory($target);continue}
   [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)
  }
 }finally{$archive.Dispose()}
}
function Get-AC8ModLayoutKind([string]$Path) {
 $kind=@()
 if(Test-Path -LiteralPath (Join-Path $Path 'Scripts\main.lua') -PathType Leaf){$kind+='Lua'}
 if(Test-Path -LiteralPath (Join-Path $Path 'dlls\main.dll') -PathType Leaf){$kind+='C++'}
 return ($kind -join '+')
}
function Find-AC8ModRoots([string]$Root,[int]$Depth=0) {
 # Folders with the standard UE4SS mod layout, outermost first; a found mod is not searched further.
 $kind=Get-AC8ModLayoutKind $Root
 if($kind){return @([pscustomobject]@{Path=[IO.Path]::GetFullPath($Root);Kind=$kind})}
 if($Depth -ge 6){return @()}
 $found=@()
 foreach($dir in @(Get-ChildItem -LiteralPath $Root -Directory -Force | Sort-Object Name)){
  if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
  $found+=@(Find-AC8ModRoots $dir.FullName ($Depth+1))
 }
 return $found
}
function Get-AC8ModNameFromSource([string]$Source) {
 # A mod packed without its own folder takes its name from the zip or folder name ("Some Mod v1.2.zip" -> SomeMod).
 $name=[IO.Path]::GetFileNameWithoutExtension($Source.TrimEnd('\','/'))
 $name=($name -replace '(?i)[ _.-]*v?\d+(\.\d+)+.*$','') -replace '[^A-Za-z0-9_.\-]',''
 return $name.TrimStart('_','.','-')
}
function New-AC8ExtraModPlan([string]$DataRoot,[string]$Source) {
 # Inspect a zip or folder without changing ue4ss-mods. A zip is unpacked into ue4ss-mods-staging; always finish
 # with Remove-AC8ExtraModPlan. Items: Name, Kind, Path, Problem, Existing (enabled/disabled/$null).
 $mods=Join-Path $DataRoot 'ue4ss-mods';[void][IO.Directory]::CreateDirectory($mods)
 $source=[IO.Path]::GetFullPath($Source).TrimEnd('\','/');$staging=$null
 if(Test-Path -LiteralPath $source -PathType Leaf){
  if([IO.Path]::GetExtension($source) -ine '.zip'){throw '只支持 .zip 压缩包或文件夹。7z／rar 请先解压，再选择解压出来的文件夹。'}
  $staging=Join-Path $DataRoot ('ue4ss-mods-staging\'+[guid]::NewGuid().ToString('N'))
  try{Expand-AC8ModArchive $source $staging}catch{Remove-AC8ExtraModTree $staging;throw}
  $scan=$staging
 }elseif(Test-Path -LiteralPath $source -PathType Container){
  $inside=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\')+'\'
  if(($source+'\').StartsWith($inside,[StringComparison]::OrdinalIgnoreCase)){throw '请选择数据文件夹以外的 Mod（例如下载并解压后的文件夹）。'}
  $links=@(Get-AC8ModTreeLinks $source);if($links.Count){throw ('文件夹里有文件系统链接，已拒绝：'+$links[0])}
  $scan=$source
 }else{throw "找不到：$Source"}
 $items=@();$warnings=@()
 foreach($root in @(Find-AC8ModRoots $scan)){
  $name=if($root.Path -eq [IO.Path]::GetFullPath($scan)){Get-AC8ModNameFromSource $source}else{Split-Path $root.Path -Leaf}
  $problem=Get-AC8ExtraModNameProblem $name
  if(!$problem -and @($items | Where-Object {$_.Name -eq $name}).Count){$problem='同一来源里有重名的 Mod'}
  $existing=$null
  if($name -and (Test-Path -LiteralPath (Join-Path $mods $name))){$existing='enabled'}elseif($name -and (Test-Path -LiteralPath (Join-Path $mods ('_'+$name)))){$existing='disabled'}
  $items+=[pscustomobject]@{Name=$name;Kind=$root.Kind;Path=$root.Path;Problem=$problem;Existing=$existing}
 }
 $files=@(Get-ChildItem -LiteralPath $scan -Recurse -File -Force)
 $loader=@($files | Where-Object {Test-AC8ModSkippedFile $_.Name} | ForEach-Object Name | Select-Object -Unique)
 if($loader.Count){$warnings+=('含有 UE4SS 本体文件（'+($loader -join '、')+'），不会安装：本整合包已经自带 UE4SS。')}
 # Only Pak files outside every mod folder are left out (game Paks such as LogicMods or ~mods).
 $roots=@($items | ForEach-Object {$_.Path.TrimEnd('\')+'\'})
 if(@($files | Where-Object {$_.Extension -in @('.pak','.utoc','.ucas')} | Where-Object {$file=$_.FullName;!@($roots | Where-Object {$file.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)}).Count}).Count){$warnings+='含有 .pak 资源文件，不会安装：Pak 由游戏自身加载，需要时请按该 Mod 的说明手动放入游戏目录。'}
 $shared=@(Get-ChildItem -LiteralPath $scan -Recurse -Directory -Force -Filter 'shared' | ForEach-Object {Get-ChildItem -LiteralPath $_.FullName -Directory -Force} | Where-Object {$_.Name -ne 'UEHelpers'} | ForEach-Object Name | Select-Object -Unique)
 if($shared.Count){$warnings+=('含有共享库（'+($shared -join '、')+'），不会安装：本包只附带 UEHelpers，依赖其他共享库的 Mod 可能无法工作。')}
 if(@($items | Where-Object {!$_.Problem -and $_.Kind -match 'C\+\+'}).Count){$warnings+='C++ Mod 会在游戏中运行原生代码：只安装可信来源的 Mod，并确认它适用于本包的 UE4SS 版本（3.0.1 实验版 e3ba1016），否则可能无法加载或导致崩溃。'}
 return [pscustomobject]@{Source=$source;Staging=$staging;Items=$items;Warnings=$warnings}
}
function Remove-AC8ExtraModTree([string]$Path) {
 # Deletes without following filesystem links (Windows PowerShell 5.1 Remove-Item -Recurse does follow them).
 if(!$Path -or !(Test-Path -LiteralPath $Path)){return}
 $item=Get-Item -LiteralPath $Path -Force
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or !$item.PSIsContainer){if($item.PSIsContainer){[IO.Directory]::Delete($item.FullName,$false)}else{$item.Attributes='Normal';$item.Delete()};return}
 foreach($child in @(Get-ChildItem -LiteralPath $Path -Force)){Remove-AC8ExtraModTree $child.FullName}
 [IO.Directory]::Delete($item.FullName,$false)
}
function Remove-AC8ExtraModPlan($Plan) {if($Plan -and $Plan.Staging){Remove-AC8ExtraModTree $Plan.Staging}}
function Get-AC8ExtraModBackupFolder([string]$DataRoot) {
 $folder=Join-Path $DataRoot ('ue4ss-mods-removed\'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
 [void][IO.Directory]::CreateDirectory($folder);return $folder
}
function Install-AC8ExtraModPlan($Plan,[string]$DataRoot,[bool]$Replace=$false) {
 # Copies each valid item into ue4ss-mods. An existing mod is skipped, or with -Replace moved to ue4ss-mods-removed
 # first and replaced, keeping its enabled/disabled state. Returns Name, Status (added/replaced/skipped/invalid), Message.
 $mods=Join-Path $DataRoot 'ue4ss-mods';[void][IO.Directory]::CreateDirectory($mods)
 $work=Join-Path $DataRoot ('ue4ss-mods-staging\copy-'+[guid]::NewGuid().ToString('N'))
 $results=@();$backup=$null
 try{
  foreach($item in @($Plan.Items)){
   if($item.Problem){$results+=[pscustomobject]@{Name=$item.Name;Status='invalid';Message=$item.Problem};continue}
   if($item.Existing -and !$Replace){$results+=[pscustomobject]@{Name=$item.Name;Status='skipped';Message='已存在，未替换'};continue}
   $target=if($item.Existing -eq 'disabled'){'_'+$item.Name}else{$item.Name}
   $copy=Join-Path $work $item.Name;Copy-AC8ModTree $item.Path $copy
   if($item.Existing){
    if(!$backup){$backup=Get-AC8ExtraModBackupFolder $DataRoot}
    [IO.Directory]::Move((Join-Path $mods $target),(Join-Path $backup $target))
    try{[IO.Directory]::Move($copy,(Join-Path $mods $target))}catch{[IO.Directory]::Move((Join-Path $backup $target),(Join-Path $mods $target));throw}
   }else{[IO.Directory]::Move($copy,(Join-Path $mods $target))}
   $results+=[pscustomobject]@{Name=$item.Name;Status=$(if($item.Existing){'replaced'}else{'added'});Message=$(if($item.Existing){'已替换（旧版本移到 ue4ss-mods-removed）'}else{'已添加'})}
  }
 }finally{Remove-AC8ExtraModTree $work}
 return $results
}
function Set-AC8ExtraModEnabled([string]$DataRoot,[string]$Name,[bool]$Enabled) {
 # Enabled: the folder name without leading _; disabled: _ + name (what Get-AC8ExtraMods skips).
 $mods=Join-Path $DataRoot 'ue4ss-mods';$path=Join-Path $mods $Name
 if(!$Name -or $Name.Contains('\') -or $Name.Contains('/') -or !(Test-Path -LiteralPath $path -PathType Container)){throw "找不到附加 Mod：$Name"}
 $plain=$Name.TrimStart('_')
 if($Enabled){
  $problem=Get-AC8ExtraModNameProblem $plain;if($problem){throw ("无法启用 $Name：$problem。请先在文件夹中改名。")}
  $target=$plain
 }else{$target='_'+$plain}
 if($target -ceq $Name){return $Name}
 if(Test-Path -LiteralPath (Join-Path $mods $target)){throw "已有同名文件夹 $target，请先处理重复的 Mod。"}
 [IO.Directory]::Move($path,(Join-Path $mods $target));return $target
}
function Remove-AC8ExtraMod([string]$DataRoot,[string]$Name) {
 # Not deleted: moved to ue4ss-mods-removed\<time>\<name>, where it can be restored by moving it back.
 $mods=Join-Path $DataRoot 'ue4ss-mods';$path=Join-Path $mods $Name
 if(!$Name -or $Name.Contains('\') -or $Name.Contains('/') -or !(Test-Path -LiteralPath $path -PathType Container)){throw "找不到附加 Mod：$Name"}
 $backup=Get-AC8ExtraModBackupFolder $DataRoot
 [IO.Directory]::Move($path,(Join-Path $backup $Name));return (Join-Path $backup $Name)
}
