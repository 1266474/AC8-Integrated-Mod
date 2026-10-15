function Read-FeatureSettings([string]$Path) {
 $mode='full';$seen=$false
 if(Test-Path -LiteralPath $Path){
  foreach($line in Get-Content -LiteralPath $Path){
   $clean=$line.Trim();if(!$clean -or $clean.StartsWith(';')){continue}
   if($seen){throw 'Duplicate or mixed feature settings. Keep one missile_mode entry.'}
   if($clean -match '^missile_mode\s*=\s*(guidance|full|none)$'){$mode=$Matches[1].ToLowerInvariant()}
   elseif($clean -match '^missile_enhancement\s*=\s*([01])$'){$mode=if($Matches[1] -eq '1'){'full'}else{'none'}}
   else{throw "Invalid feature setting: $clean"}
   $seen=$true
  }
 }
 $count=switch($mode){'guidance'{32} 'full'{375} 'none'{0}}
 return [pscustomobject]@{MissileMode=$mode;MissileEnhancement=($mode -ne 'none');ExpectedFields=$count}
}
function Get-AC8ExtraMods([string]$DataRoot) {
 # Other UE4SS mods placed in ue4ss-mods of the player data folder (2.4.3; the package folder when portable,
 # <install>\data for the installed app). A folder with the standard UE4SS layout (Scripts\main.lua
 # and/or dlls\main.dll) is deployed with this package's UE4SS and enabled; a folder starting with _ is disabled. Names
 # reserved by this package, unusual names and filesystem links are skipped with a reason.
 $folder=Join-Path $DataRoot 'ue4ss-mods'
 if(!(Test-Path -LiteralPath $folder -PathType Container)){return @()}
 $reserved=@('AC8MouseAim','AC8SourceInit','shared')
 $link=[IO.FileAttributes]::ReparsePoint
 return @(foreach($dir in @(Get-ChildItem -LiteralPath $folder -Directory -Force | Sort-Object Name)){
  $name=$dir.Name;$problem=$null;$kind=@()
  if($name.StartsWith('_')){$problem='已停用（名称以 _ 开头）'}
  elseif($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.\-]{0,63}$'){$problem='名称只能使用英文字母、数字和 _ . -'}
  elseif($reserved -contains $name){$problem='与本整合包自带的组件同名'}
  elseif(($dir.Attributes -band $link) -or @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force | Where-Object {$_.Attributes -band $link}).Count){$problem='包含文件系统链接'}
  else{
   if(Test-Path -LiteralPath (Join-Path $dir.FullName 'Scripts/main.lua') -PathType Leaf){$kind+='Lua'}
   if(Test-Path -LiteralPath (Join-Path $dir.FullName 'dlls/main.dll') -PathType Leaf){$kind+='C++'}
   if(!$kind.Count){$problem='不是 UE4SS Mod（缺少 Scripts\main.lua 或 dlls\main.dll）'}
  }
  [pscustomobject]@{Name=$name;Path=$dir.FullName;Kind=($kind -join '+');Problem=$problem}
 })
}
function Install-SelectedUE4SS([string]$PayloadRoot,[string]$Destination,$Features,$ExtraMods=@()) {
 $source=[IO.Path]::GetFullPath($PayloadRoot);$target=[IO.Path]::GetFullPath($Destination)
 if($source.Equals($target,[StringComparison]::OrdinalIgnoreCase)){throw 'Payload and staging directory must differ.'}
 if($Features.MissileMode -notin @('none','guidance','full')){throw 'Invalid missile mode.'}
 if(@(Get-ChildItem -LiteralPath $target -Force | Where-Object Name -ne 'AC8SourceInit-owner.txt').Count){throw 'Staging directory is not empty; finish owned cleanup first.'}
 foreach($file in Get-ChildItem -LiteralPath $source -Force){
  if($file.Name -eq 'Mods'){continue}
  Copy-Item -LiteralPath $file.FullName -Destination $target -Recurse
 }
 $mods=Join-Path $target 'Mods';New-Item -ItemType Directory -Path $mods -Force | Out-Null
 Copy-Item -LiteralPath (Join-Path $source 'Mods/AC8MouseAim') -Destination $mods -Recurse
 # UE4SS shared Lua library (UEHelpers) of the same UE4SS build, used by many other Lua mods.
 $shared=Join-Path $source 'Mods/shared';if(Test-Path -LiteralPath $shared){Copy-Item -LiteralPath $shared -Destination $mods -Recurse}
 if($Features.MissileEnhancement){
  Copy-Item -LiteralPath (Join-Path $source 'Mods/AC8SourceInit') -Destination $mods -Recurse
  Set-Content -LiteralPath (Join-Path $mods 'AC8SourceInit/Scripts/installation_mode.lua') -Value ("return '"+$Features.MissileMode+"'") -Encoding ASCII
 }
 $lines=@('AC8MouseAim : 1')
 if($Features.MissileEnhancement){$lines=@('AC8SourceInit : 1')+$lines}
 # Extra mods load after this package's own mods (mods.txt order).
 foreach($extra in @($ExtraMods | Where-Object {$_ -and !$_.Problem})){
  Copy-Item -LiteralPath $extra.Path -Destination (Join-Path $mods $extra.Name) -Recurse
  $lines+=($extra.Name+' : 1')
 }
 Set-Content -LiteralPath (Join-Path $mods 'mods.txt') -Value $lines -Encoding ASCII
}
function Get-FeatureReadinessPattern($Features) {
 if($Features.MissileEnhancement){return '\[AC8SourceInit\].*SOURCE_APPLIED mode='+$Features.MissileMode+'\b.*verified='+$Features.ExpectedFields+'\b'}
 return '\[AC8MouseAim\].*Loaded\.'
}
