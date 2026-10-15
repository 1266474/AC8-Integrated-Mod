. (Join-Path $PSScriptRoot 'ExtraMods-Settings.ps1')
# Launcher dialog for the extra UE4SS mods (2.5.0): list, add from zip or folder (also by drag and drop), enable or
# disable, remove to ue4ss-mods-removed. Changes apply at the next launch.
function Update-AC8ExtraModsDialog($Context) {
 $ctx=$Context;$ctx.Rows.Children.Clear()
 $mods=@(Get-AC8ExtraMods $ctx.Root)
 $ctx.Empty.Visibility=if($mods.Count){'Collapsed'}else{'Visible'}
 foreach($mod in $mods){
  $row=[Windows.Controls.Grid]::new();$row.Margin=[Windows.Thickness]::new(0,0,0,10)
  foreach($width in @([Windows.GridLength]::new(1,[Windows.GridUnitType]::Star),[Windows.GridLength]::Auto,[Windows.GridLength]::Auto)){$column=[Windows.Controls.ColumnDefinition]::new();$column.Width=$width;[void]$row.ColumnDefinitions.Add($column)}
  $info=[Windows.Controls.StackPanel]::new();$info.VerticalAlignment='Center'
  $kind=if($mod.Kind){$mod.Kind}else{Get-AC8ModLayoutKind $mod.Path}
  $title=[Windows.Controls.TextBlock]::new();$title.Text=$mod.Name+$(if($kind){'  ·  '+$kind}else{''});$title.FontWeight='SemiBold';$title.TextWrapping='Wrap';[void]$info.Children.Add($title)
  $state=[Windows.Controls.TextBlock]::new();$state.TextWrapping='Wrap';$state.FontSize=12;$state.Margin=[Windows.Thickness]::new(0,2,0,0)
  if(!$mod.Problem){$state.Text='下次启动加载';$state.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'CxGood')}
  elseif($mod.Name.StartsWith('_')){$state.Text='已停用';$state.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'CxMuted')}
  else{$state.Text='不会加载：'+$mod.Problem;$state.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'CxWarn')}
  [void]$info.Children.Add($state);[void]$row.Children.Add($info)
  $toggle=[Windows.Controls.Button]::new();$toggle.Content=if($mod.Name.StartsWith('_')){'启用'}else{'停用'};$toggle.Tag=$mod.Name;$toggle.Margin=[Windows.Thickness]::new(12,0,8,0);$toggle.MinWidth=72
  [Windows.Automation.AutomationProperties]::SetName($toggle,([string]$toggle.Content+' '+$mod.Name));[Windows.Controls.Grid]::SetColumn($toggle,1)
  $toggle.Add_Click({param($sender,$event) & $ctx.Commands.Toggle $ctx ([string]$sender.Tag)}.GetNewClosure());[void]$row.Children.Add($toggle)
  $remove=[Windows.Controls.Button]::new();$remove.Content='删除…';$remove.Tag=$mod.Name;$remove.MinWidth=72
  [Windows.Automation.AutomationProperties]::SetName($remove,('删除 '+$mod.Name));[Windows.Controls.Grid]::SetColumn($remove,2)
  $remove.Add_Click({param($sender,$event) & $ctx.Commands.Remove $ctx ([string]$sender.Tag)}.GetNewClosure());[void]$row.Children.Add($remove)
  [void]$ctx.Rows.Children.Add($row)
 }
}
function Switch-AC8ExtraModFromDialog($Context,[string]$Name) {
 try{
  $enable=$Name.StartsWith('_');$new=Set-AC8ExtraModEnabled $Context.Root $Name $enable;$Context.Changed=$true
  $Context.Status.Text=if($enable){"已启用 $new，下次启动加载。"}else{"已停用 $($Name)（文件夹改为 $new），下次启动不再加载。"}
 }catch{$Context.Status.Text=$_.Exception.Message}
 Update-AC8ExtraModsDialog $Context
}
function Remove-AC8ExtraModFromDialog($Context,[string]$Name) {
 $message="删除附加 Mod：$Name？`n`n文件夹会移到 ue4ss-mods-removed，需要时可以移回 ue4ss-mods 恢复。"
 if(!(& $Context.Commands.Confirm $Context.Window $message '删除附加 Mod' '删除')){$Context.Status.Text='已取消，没有改动。';return}
 try{$backup=Remove-AC8ExtraMod $Context.Root $Name;$Context.Changed=$true;$Context.Status.Text="已删除 $Name，备份在 $backup。"}catch{$Context.Status.Text=$_.Exception.Message}
 Update-AC8ExtraModsDialog $Context
}
function Add-AC8ExtraModFromDialog($Context,[string]$Source) {
 $plan=$null
 try{
  $plan=New-AC8ExtraModPlan $Context.Root $Source
  $valid=@($plan.Items | Where-Object {!$_.Problem});$invalid=@($plan.Items | Where-Object {$_.Problem})
  if(!$plan.Items.Count){throw ('没有在 '+[IO.Path]::GetFileName($Source)+' 中找到 UE4SS Mod：需要含有 Scripts\main.lua 或 dlls\main.dll 的文件夹。')}
  if(!$valid.Count){throw ('找到的 Mod 都不能安装：'+(($invalid | ForEach-Object {$(if($_.Name){$_.Name}else{'（无名称）'})+'（'+$_.Problem+'）'}) -join '、'))}
  $lines=@('将添加到附加 Mod，下次启动生效：')
  foreach($item in $valid){$lines+=('· '+$item.Name+'（'+$item.Kind+'）'+$(if($item.Existing){'：替换已有的版本，旧版本移到 ue4ss-mods-removed'}else{''}))}
  foreach($item in $invalid){$lines+=('· 跳过 '+$(if($item.Name){$item.Name}else{'（无名称）'})+'：'+$item.Problem)}
  foreach($warning in @($plan.Warnings)){$lines+=('注意：'+$warning)}
  if(!(& $Context.Commands.Confirm $Context.Window ($lines -join "`n") '添加附加 Mod' '添加')){$Context.Status.Text='已取消，没有改动。';return}
  $results=@(Install-AC8ExtraModPlan $plan $Context.Root $true)
  $Context.Changed=$true
  $Context.Status.Text=(($results | ForEach-Object {$_.Name+'：'+$_.Message}) -join '；')+'。下次启动生效。'
 }catch{$Context.Status.Text=$_.Exception.Message}
 finally{Remove-AC8ExtraModPlan $plan;Update-AC8ExtraModsDialog $Context}
}
function Confirm-AC8ExtraModAction($Owner,[string]$Message,[string]$Title,[string]$Action) {
 return Show-CreeperUXConfirmation $Owner $Message -Title $Title -ConfirmText $Action -WindowTitle ('AC8 · '+$Title)
}
function New-AC8ExtraModsDialog([string]$Root,$Owner,[ValidateSet('dark','light')][string]$Theme='dark') {
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
 $xml=[xml](Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ExtraMods-GUI.xaml') -Raw -Encoding UTF8)
 $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml));if($Owner){$dialog.Owner=$Owner}
 Set-CreeperUXTheme $dialog $Theme
 Set-AC8WindowIcon $dialog
 $area=[Windows.SystemParameters]::WorkArea;$dialog.Width=[Math]::Min($dialog.Width,$area.Width-24);$dialog.Height=[Math]::Min($dialog.Height,$area.Height-24);$dialog.MinWidth=[Math]::Min($dialog.MinWidth,$dialog.Width);$dialog.MinHeight=[Math]::Min($dialog.MinHeight,$dialog.Height)
 [void][IO.Directory]::CreateDirectory((Join-Path $Root 'ue4ss-mods'))
 # Event handlers are GetNewClosure() closures, which resolve commands only at global scope: they call through the
 # context (as the key-settings dialog does), so the dialog works however the launcher was started.
 $commands=@{Refresh=${function:Update-AC8ExtraModsDialog};Toggle=${function:Switch-AC8ExtraModFromDialog};Remove=${function:Remove-AC8ExtraModFromDialog};Add=${function:Add-AC8ExtraModFromDialog};Confirm=${function:Confirm-AC8ExtraModAction}}
 $ctx=[pscustomobject]@{Window=$dialog;Root=$Root;Rows=$dialog.FindName('ModRows');Empty=$dialog.FindName('EmptyHint');Status=$dialog.FindName('ModStatus');Commands=$commands;Changed=$false}
 $dialog.FindName('AddModZip').Add_Click({
  $picker=New-Object Microsoft.Win32.OpenFileDialog;$picker.Title='选择 UE4SS Mod 压缩包';$picker.Filter='UE4SS Mod 压缩包 (*.zip)|*.zip';$picker.CheckFileExists=$true
  if($picker.ShowDialog($ctx.Window)){& $ctx.Commands.Add $ctx $picker.FileName}
 }.GetNewClosure())
 $dialog.FindName('AddModFolder').Add_Click({
  $picker=New-Object System.Windows.Forms.FolderBrowserDialog;$picker.Description='选择已解压的 Mod 文件夹（也可以是包含多个 Mod 的文件夹）';$picker.ShowNewFolderButton=$false
  try{if($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK){& $ctx.Commands.Add $ctx $picker.SelectedPath}}finally{$picker.Dispose()}
 }.GetNewClosure())
 $dialog.FindName('OpenModsFolder').Add_Click({
  try{Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"'+(Join-Path $ctx.Root 'ue4ss-mods')+'"')}catch{$ctx.Status.Text=$_.Exception.Message}
 }.GetNewClosure())
 $dialog.FindName('CloseMods').Add_Click({$ctx.Window.Close()}.GetNewClosure())
 $dialog.Add_DragOver({param($sender,$event) $event.Effects=if($event.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){[Windows.DragDropEffects]::Copy}else{[Windows.DragDropEffects]::None};$event.Handled=$true})
 $dialog.Add_Drop({param($sender,$event)
  if(!$event.Data.GetDataPresent([Windows.DataFormats]::FileDrop)){return}
  foreach($path in @($event.Data.GetData([Windows.DataFormats]::FileDrop))){& $ctx.Commands.Add $ctx ([string]$path)}
 }.GetNewClosure())
 & $commands.Refresh $ctx
 return $ctx
}
function Show-AC8ExtraModsDialog([string]$Root,$Owner,[string]$Theme='dark') {
 $context=New-AC8ExtraModsDialog $Root $Owner $Theme
 [void]$context.Window.ShowDialog();return $context
}
