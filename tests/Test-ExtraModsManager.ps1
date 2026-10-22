$ErrorActionPreference='Stop'
# Extra UE4SS mod management (2.5.0): plans from zips and folders (layout search, names, duplicates, conflicts, warnings,
# unsafe paths, links), install and replace keeping the enabled state, enable/disable, removal to a backup, and the
# launcher dialog driven through its real buttons. Run with the call operator (a script scope, not global), like the
# key-settings test, so the dialog's handlers cannot depend on global functions. Temporary folders only.
$repo=Split-Path $PSScriptRoot -Parent;$template=Join-Path $repo 'package-template'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
. (Join-Path $template 'ExtraMods-Settings.ps1')
$fixture=Join-Path $repo ('native/test-runtime/extramods-manager-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $fixture 'data';$src=Join-Path $fixture 'downloads';New-Item -ItemType Directory -Path $data,$src -Force | Out-Null
function Assert-True([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function New-TestZip([string]$Name,[hashtable]$Files){
 $zip=Join-Path $src $Name;$archive=[IO.Compression.ZipFile]::Open($zip,'Create')
 try{foreach($entry in $Files.Keys){$item=$archive.CreateEntry($entry);$writer=New-Object IO.StreamWriter($item.Open());$writer.Write([string]$Files[$entry]);$writer.Dispose()}}finally{$archive.Dispose()}
 return $zip
}
function Get-ModNames{return ((@(Get-ChildItem -LiteralPath (Join-Path $data 'ue4ss-mods') -Directory -Force | ForEach-Object Name) | Sort-Object) -join ',')}
function Join-Names([string[]]$Names){return ((@($Names) | Sort-Object) -join ',')}
$mods=Join-Path $data 'ue4ss-mods';$checks=0

# ---- zip with a nested mod, the UE4SS loader, a pak and a second shared library ----
$zip=New-TestZip 'Pack.zip' @{'Pack/ue4ss/UE4SS.dll'='x';'Pack/ue4ss/Mods/ModA/Scripts/main.lua'='print(1)';'Pack/ue4ss/Mods/ModA/enabled.txt'='';'Pack/ue4ss/Mods/shared/OtherLib/lib.lua'='x';'Pack/ue4ss/Mods/shared/UEHelpers/UEHelpers.lua'='x';'Pack/Content/Paks/LogicMods/ModA.pak'='x'}
$plan=New-AC8ExtraModPlan $data $zip
Assert-True (@($plan.Items).Count -eq 1 -and $plan.Items[0].Name -eq 'ModA' -and $plan.Items[0].Kind -eq 'Lua' -and !$plan.Items[0].Problem -and !$plan.Items[0].Existing) 'nested mod found'
$text=$plan.Warnings -join ' | '
Assert-True (@($plan.Warnings).Count -eq 3 -and $text -match 'UE4SS\.dll' -and $text -match '\.pak' -and $text -match 'OtherLib' -and $text -notmatch '共享库（[^）]*UEHelpers') ('warnings: '+$text)
Assert-True (@(Get-ChildItem -LiteralPath $mods -Force).Count -eq 0) 'a plan must not change ue4ss-mods'
$results=@(Install-AC8ExtraModPlan $plan $data $false);Remove-AC8ExtraModPlan $plan
Assert-True ($results[0].Status -eq 'added' -and (Get-ModNames) -eq 'ModA' -and (Test-Path -LiteralPath (Join-Path $mods 'ModA\Scripts\main.lua')) -and (Test-Path -LiteralPath (Join-Path $mods 'ModA\enabled.txt'))) 'ModA installed'
Assert-True (!@(Get-ChildItem -LiteralPath $data -Recurse -Force -File | Where-Object {$_.Name -in @('UE4SS.dll','ModA.pak','lib.lua')}).Count) 'loader, pak and other shared library not installed'
Assert-True (!@(Get-ChildItem -LiteralPath (Join-Path $data 'ue4ss-mods-staging') -Force).Count) 'staging cleaned'
$listed=@(Get-AC8ExtraMods $data);Assert-True ($listed.Count -eq 1 -and !$listed[0].Problem -and $listed[0].Kind -eq 'Lua') 'ModA will load'
$checks++

# ---- a mod without its own folder; replace keeps the disabled state; enable/disable; remove to a backup ----
$plan=New-AC8ExtraModPlan $data (New-TestZip 'Cool Mod v1.2.zip' @{'Scripts/main.lua'='print(2)'})
Assert-True ($plan.Items[0].Name -eq 'CoolMod') ('name from the zip: '+$plan.Items[0].Name)
$null=Install-AC8ExtraModPlan $plan $data $false;Remove-AC8ExtraModPlan $plan
Assert-True ((Set-AC8ExtraModEnabled $data 'ModA' $false) -eq '_ModA' -and (Get-ModNames) -eq (Join-Names '_ModA','CoolMod')) 'disabled with _'
Assert-True (@(Get-AC8ExtraMods $data | Where-Object {$_.Name -eq '_ModA' -and $_.Problem}).Count -eq 1) 'disabled mod is skipped at launch'
$plan=New-AC8ExtraModPlan $data (New-TestZip 'ModA-2.0.zip' @{'ModA/Scripts/main.lua'='print(3)'})
Assert-True ($plan.Items[0].Existing -eq 'disabled') 'existing disabled copy detected'
$results=@(Install-AC8ExtraModPlan $plan $data $false)
Assert-True ($results[0].Status -eq 'skipped' -and (Get-Content -LiteralPath (Join-Path $mods '_ModA\Scripts\main.lua') -Raw) -eq 'print(1)') 'no replacement without consent'
$results=@(Install-AC8ExtraModPlan $plan $data $true);Remove-AC8ExtraModPlan $plan
Assert-True ($results[0].Status -eq 'replaced' -and (Get-Content -LiteralPath (Join-Path $mods '_ModA\Scripts\main.lua') -Raw) -eq 'print(3)') 'replaced and still disabled'
$old=@(Get-ChildItem -LiteralPath (Join-Path $data 'ue4ss-mods-removed') -Recurse -Filter 'main.lua')
Assert-True ($old.Count -eq 1 -and (Get-Content -LiteralPath $old[0].FullName -Raw) -eq 'print(1)') 'replaced version kept in ue4ss-mods-removed'
Assert-True ((Set-AC8ExtraModEnabled $data '_ModA' $true) -eq 'ModA') 'enabled again'
New-Item -ItemType Directory -Path (Join-Path $mods '_ModA') | Out-Null
$caught=$false;try{Set-AC8ExtraModEnabled $data 'ModA' $false}catch{$caught=$true}
Assert-True ($caught -and (Test-Path -LiteralPath (Join-Path $mods 'ModA'))) 'disabling onto an existing _ folder must be refused'
Remove-Item -LiteralPath (Join-Path $mods '_ModA')
$backup=Remove-AC8ExtraMod $data 'CoolMod'
Assert-True (!(Test-Path -LiteralPath (Join-Path $mods 'CoolMod')) -and (Test-Path -LiteralPath (Join-Path $backup 'Scripts\main.lua'))) 'removed to the backup folder'
$caught=$false;try{Remove-AC8ExtraMod $data '..\data'}catch{$caught=$true};Assert-True $caught 'path outside ue4ss-mods refused'
$checks++

# ---- folders: several mods, C++ warning, invalid and reserved names, links, the data folder itself, 7z ----
$folder=Join-Path $src 'unpacked'
foreach($rel in 'Mods\ModB\dlls\main.dll','Mods\ModC\Scripts\main.lua','Mods\Bad Name\Scripts\main.lua','Mods\AC8MouseAim\Scripts\main.lua'){$file=Join-Path $folder $rel;New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null;[IO.File]::WriteAllText($file,'x')}
$plan=New-AC8ExtraModPlan $data $folder;$byName=@{};foreach($item in $plan.Items){$byName[$item.Name]=$item}
Assert-True (@($plan.Items).Count -eq 4 -and $byName['ModB'].Kind -eq 'C++' -and !$byName['ModC'].Problem -and $byName['Bad Name'].Problem -and $byName['AC8MouseAim'].Problem -and !$plan.Staging) 'folder plan'
Assert-True (($plan.Warnings -join ' ') -match 'C\+\+') 'C++ caution'
$results=@(Install-AC8ExtraModPlan $plan $data $true)
Assert-True (@($results | Where-Object Status -eq 'added').Count -eq 2 -and @($results | Where-Object Status -eq 'invalid').Count -eq 2 -and (Get-ModNames) -eq (Join-Names 'ModA','ModB','ModC')) 'only valid mods added'
Assert-True ((Test-Path -LiteralPath (Join-Path $folder 'Mods\ModB\dlls\main.dll')) -and (Test-Path -LiteralPath (Join-Path $folder 'Mods\Bad Name'))) 'source folder untouched'
$outside=Join-Path $fixture 'outside';New-Item -ItemType Directory -Path (Join-Path $outside 'Scripts') -Force | Out-Null;[IO.File]::WriteAllText((Join-Path $outside 'Scripts\main.lua'),'x')
$linked=Join-Path $src 'linked';New-Item -ItemType Directory -Path $linked | Out-Null;New-Item -ItemType Junction -Path (Join-Path $linked 'LinkMod') -Target $outside | Out-Null
$caught=$false;try{New-AC8ExtraModPlan $data $linked}catch{$caught=$true};Assert-True $caught 'folder with a link refused'
[IO.Directory]::Delete((Join-Path $linked 'LinkMod'),$false);Assert-True (Test-Path -LiteralPath (Join-Path $outside 'Scripts\main.lua')) 'link target untouched'
$caught=$false;try{New-AC8ExtraModPlan $data $mods}catch{$caught=$true};Assert-True $caught 'the data folder itself refused'
$archive7z=Join-Path $src 'mod.7z';[IO.File]::WriteAllText($archive7z,'x');$caught=$false;try{New-AC8ExtraModPlan $data $archive7z}catch{$caught=$true};Assert-True $caught '7z refused with a hint'
$checks++

# ---- unsafe or empty zips, duplicates ----
$caught=$false;try{New-AC8ExtraModPlan $data (New-TestZip 'slip.zip' @{'../evil/Scripts/main.lua'='x'})}catch{$caught=$true}
Assert-True ($caught -and !(Test-Path -LiteralPath (Join-Path $fixture 'evil')) -and !@(Get-ChildItem -LiteralPath (Join-Path $data 'ue4ss-mods-staging') -Force).Count) 'path traversal refused and staging cleaned'
$plan=New-AC8ExtraModPlan $data (New-TestZip 'readme.zip' @{'readme.txt'='x'});Assert-True (!@($plan.Items).Count) 'no mod in the zip';Remove-AC8ExtraModPlan $plan
$plan=New-AC8ExtraModPlan $data (New-TestZip 'dup.zip' @{'a/ModD/Scripts/main.lua'='x';'b/ModD/Scripts/main.lua'='y'})
Assert-True (@($plan.Items | Where-Object Problem).Count -eq 1 -and @($plan.Items | Where-Object {!$_.Problem}).Count -eq 1) 'duplicate names in one source';Remove-AC8ExtraModPlan $plan
$checks++

# ---- 2.5.2: a mod that mounts its own IoStore assets (PW-MkI layout) is installed complete ----
$pw=New-TestZip 'PW-Like-1.1.3.zip' @{'PW/Runtime/dwmapi.dll'='x';'PW/Runtime/ue4ss/UE4SS.dll'='x';'PW/Runtime/ue4ss/Mods/mods.txt'='x';
 'PW/Runtime/ue4ss/Mods/AC8OverrideLoader/dlls/main.dll'='dll';'PW/Runtime/ue4ss/Mods/AC8OverrideLoader/dlls/feature.enabled'='on';
 'PW/Runtime/ue4ss/Mods/AC8OverrideLoader/payloads/PWMkI/Asset_P.pak'='pak';'PW/Runtime/ue4ss/Mods/AC8OverrideLoader/payloads/PWMkI/Asset_P.ucas'='ucas';
 'PW/Runtime/ue4ss/Mods/AC8OverrideLoader/payloads/PWMkI/Asset_P.utoc'='utoc';'PW/Runtime/ue4ss/Mods/PWMkI/Scripts/main.lua'='print(1)'}
$plan=New-AC8ExtraModPlan $data $pw;$byName=@{};foreach($item in $plan.Items){$byName[$item.Name]=$item}
Assert-True (@($plan.Items).Count -eq 2 -and $byName['AC8OverrideLoader'].Kind -eq 'C++' -and $byName['PWMkI'].Kind -eq 'Lua') 'PW-like mods found'
Assert-True (($plan.Warnings -join ' ') -notmatch '\.pak' -and ($plan.Warnings -join ' ') -match 'UE4SS\.dll') ('pak inside a mod is not a warning: '+($plan.Warnings -join ' | '))
$results=@(Install-AC8ExtraModPlan $plan $data $true);Remove-AC8ExtraModPlan $plan
foreach($rel in 'AC8OverrideLoader\payloads\PWMkI\Asset_P.pak','AC8OverrideLoader\payloads\PWMkI\Asset_P.ucas','AC8OverrideLoader\payloads\PWMkI\Asset_P.utoc','AC8OverrideLoader\dlls\feature.enabled','PWMkI\Scripts\main.lua'){Assert-True (Test-Path -LiteralPath (Join-Path $mods $rel)) ('missing after install: '+$rel)}
Assert-True (!@(Get-ChildItem -LiteralPath $mods -Recurse -Force -File | Where-Object {$_.Name -in @('dwmapi.dll','UE4SS.dll')}).Count) 'UE4SS loader of the zip not installed'
$checks++

# ---- 2.5.2: at cleanup, deployed copies identical to ue4ss-mods are removed; what the mod wrote stays for the archive ----
. (Join-Path $template 'Cleanup-Core.ps1')
$w64=Join-Path $fixture 'game\Game\Binaries\Win64';$deployed=Join-Path $w64 'ue4ss\Mods';New-Item -ItemType Directory -Path $deployed -Force | Out-Null
foreach($name in 'AC8OverrideLoader','PWMkI','ModB'){Copy-Item -LiteralPath (Join-Path $mods $name) -Destination (Join-Path $deployed $name) -Recurse}
[IO.File]::WriteAllText((Join-Path $deployed 'PWMkI\Scripts\runtime.log'),'written by the mod')
[IO.File]::WriteAllText((Join-Path $deployed 'ModB\dlls\main.dll'),'changed while running')
Copy-Item -LiteralPath (Join-Path $mods 'ModA') -Destination (Join-Path $deployed 'AC8MouseAim') -Recurse
$state=[pscustomobject]@{ExtraMods=@(
 [pscustomobject]@{Name='AC8OverrideLoader';Source=(Join-Path $mods 'AC8OverrideLoader')},[pscustomobject]@{Name='PWMkI';Source=(Join-Path $mods 'PWMkI')},
 [pscustomobject]@{Name='ModB';Source=(Join-Path $mods 'ModB')},[pscustomobject]@{Name='AC8MouseAim';Source=(Join-Path $mods 'ModA')},[pscustomobject]@{Name='..\escape';Source=$mods})}
Remove-AC8DeployedExtraMods $w64 $state
Assert-True (!(Test-Path -LiteralPath (Join-Path $deployed 'AC8OverrideLoader'))) 'identical copy (with its payload) removed instead of archived'
Assert-True ((Test-Path -LiteralPath (Join-Path $deployed 'PWMkI\Scripts\runtime.log')) -and !(Test-Path -LiteralPath (Join-Path $deployed 'PWMkI\Scripts\main.lua'))) 'file written by the mod kept, identical file removed'
Assert-True (Test-Path -LiteralPath (Join-Path $deployed 'ModB\dlls\main.dll')) 'changed file kept for the archive'
Assert-True (Test-Path -LiteralPath (Join-Path $deployed 'AC8MouseAim\Scripts\main.lua')) "this package's own mod names are never touched"
Assert-True ((Test-Path -LiteralPath (Join-Path $mods 'AC8OverrideLoader\payloads\PWMkI\Asset_P.ucas')) -and (Test-Path -LiteralPath (Join-Path $mods 'PWMkI\Scripts\main.lua'))) 'originals in ue4ss-mods untouched'
$checks++

# ---- the launcher dialog through its real buttons and commands ----
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
. (Join-Path $template 'CreeperUX-Theme.ps1')
. (Join-Path $template 'ExtraMods-GUI.ps1')
$tokens=Get-Content -LiteralPath (Join-Path $template 'ui/creeperux/tokens.json') -Raw | ConvertFrom-Json
foreach($theme in 'dark','light'){
 $ctx=New-AC8ExtraModsDialog $data $null $theme
 if(![Windows.SystemParameters]::HighContrast){Assert-True ($ctx.Window.Resources['CxBg'].Color -eq (Convert-CxColor $tokens.color.bg.$theme)) "dialog theme $theme"}
 Assert-True ($ctx.Rows.Children.Count -eq @(Get-AC8ExtraMods $data).Count -and $ctx.Empty.Visibility -eq 'Collapsed') 'one row per mod'
 $ctx.Window.Content.Measure([Windows.Size]::new(860,720));$ctx.Window.Content.Arrange([Windows.Rect]::new(0,0,860,720));$ctx.Window.Content.UpdateLayout()
}
$global:AC8ModTestConfirm=@()
$ctx.Commands.Confirm={param($Owner,$Message,$Title,$Action) $global:AC8ModTestConfirm+=,@($Title,$Message);return $true}
$row=@($ctx.Rows.Children | Where-Object {$_.Children[1].Tag -eq 'ModB'})[0]
$row.Children[1].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert-True ((Test-Path -LiteralPath (Join-Path $mods '_ModB')) -and $ctx.Changed -and $ctx.Status.Text -match '_ModB') ('toggle button: '+$ctx.Status.Text)
$row=@($ctx.Rows.Children | Where-Object {$_.Children[1].Tag -eq '_ModB'})[0]
Assert-True ([string]$row.Children[1].Content -eq '启用') 'disabled row offers enable'
$row=@($ctx.Rows.Children | Where-Object {$_.Children[2].Tag -eq 'ModC'})[0]
$row.Children[2].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
Assert-True (!(Test-Path -LiteralPath (Join-Path $mods 'ModC')) -and $global:AC8ModTestConfirm[-1][0] -eq '删除附加 Mod' -and $ctx.Rows.Children.Count -eq @(Get-AC8ExtraMods $data).Count) 'remove button with confirmation'
& $ctx.Commands.Add $ctx (New-TestZip 'ModE.zip' @{'ModE/Scripts/main.lua'='x';'ModE/ue4ss/dwmapi.dll'='x'})
Assert-True ((Test-Path -LiteralPath (Join-Path $mods 'ModE\Scripts\main.lua')) -and $global:AC8ModTestConfirm[-1][1] -match 'ModE' -and $global:AC8ModTestConfirm[-1][1] -match 'dwmapi\.dll' -and $ctx.Rows.Children.Count -eq @(Get-AC8ExtraMods $data).Count) ('add from a zip: '+$ctx.Status.Text)
$ctx.Commands.Confirm={param($Owner,$Message,$Title,$Action) return $false}
& $ctx.Commands.Add $ctx (New-TestZip 'ModF.zip' @{'ModF/Scripts/main.lua'='x'})
Assert-True (!(Test-Path -LiteralPath (Join-Path $mods 'ModF')) -and !@(Get-ChildItem -LiteralPath (Join-Path $data 'ue4ss-mods-staging') -Force).Count) 'cancelled add changes nothing'
& $ctx.Commands.Add $ctx (New-TestZip 'empty.zip' @{'readme.txt'='x'})
Assert-True ($ctx.Status.Text -match 'Scripts\\main\.lua') 'no-mod message'
$empty=Join-Path $fixture 'empty-data';New-Item -ItemType Directory -Path $empty | Out-Null
$ctx=New-AC8ExtraModsDialog $empty $null 'dark';Assert-True ($ctx.Empty.Visibility -eq 'Visible' -and (Test-Path -LiteralPath (Join-Path $empty 'ue4ss-mods'))) 'empty hint'
$checks++
Remove-Variable -Name AC8ModTestConfirm -Scope Global
Remove-AC8ExtraModTree $fixture
Write-Host "PASS extra mod manager: $checks groups (zip and folder plans, loader/pak/shared/C++ notices, install and replace keeping state, enable/disable, removal to backup, unsafe paths and links refused, dialog buttons)"
