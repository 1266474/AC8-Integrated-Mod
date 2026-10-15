# AC8 Integrated host for the installed app (2.5.0), kept in the install root. Steam (Start-AC8-From-Steam.cmd), the
# Start menu shortcut and Apps & features start it. It resolves the current version, checks it (repairing damaged
# files from the cached verified package) and runs that version's own scripts in a separate PowerShell process.
param(
 [ValidateSet('Session','CheckOriginal','Gui','Update','Repair','Rollback','Uninstall','Status')][string]$Action='Gui',
 [string]$Feed='',[switch]$Yes,[switch]$NoRegister,[switch]$NoLaunch,[switch]$RemoveData
)
$ErrorActionPreference='Stop'
foreach($module in @('Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility')){Import-Module ([IO.Path]::Combine($PSHOME,'Modules',$module,($module+'.psd1'))) -ErrorAction Stop}
$installRoot=$PSScriptRoot
. ([IO.Path]::Combine($installRoot,'App-Core.ps1'))
$powershell=[IO.Path]::Combine($PSHOME,'powershell.exe')
function Write-AC8Findings($Findings){
 foreach($finding in @($Findings)){
  $mark=switch($finding.Status){'ok'{'[正常]  '} 'fixed'{'[已修复]'} default{'[需处理]'}}
  $color=switch($finding.Status){'ok'{'Green'} 'fixed'{'Yellow'} default{'Red'}}
  Write-Host ($mark+' '+$finding.Item+'：'+$finding.Message) -ForegroundColor $color
 }
}
function Wait-AC8Close{if(!$Yes){[void](Read-Host '按回车关闭此窗口')}}
function Start-AC8Launcher([string]$Package){
 Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList @('-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+[IO.Path]::Combine($Package,'Launcher-GUI.ps1')+'"'))
}
function Get-AC8ReadyPackage{
 # Before every launch: app.json, version files and host files, repaired offline from the cached verified package.
 $findings=@(Invoke-AC8AppRepair $installRoot -Quick -NoRegister)
 foreach($finding in @($findings | Where-Object {$_.Status -eq 'fixed'})){Write-Host ('已自动修复：'+$finding.Message) -ForegroundColor Yellow}
 $bad=@($findings | Where-Object {$_.Status -eq 'problem'})
 if($bad.Count){Stop-AC8App 'APP_DAMAGED' $bad[0].Message '请在开始菜单打开 AC8 Integrated 并使用“检查并修复”；需要时会从 GitHub 重新下载同一版本。'}
 return Get-AC8CurrentPackage $installRoot
}
try{
 switch($Action){
  'Session'{
   $package=Get-AC8ReadyPackage
   & $powershell -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($package,'Run-Console.ps1')) -Action Session
   exit $LASTEXITCODE
  }
  'CheckOriginal'{
   $package=Get-AC8CurrentPackage $installRoot
   & $powershell -NoProfile -ExecutionPolicy Bypass -File ([IO.Path]::Combine($package,'Mod-Mode.ps1')) -Action CheckOriginal
   exit $LASTEXITCODE
  }
  'Gui'{
   try{$package=Get-AC8ReadyPackage}catch{
    $message='AC8 Integrated 暂时无法打开：'+$_.Exception.Message+[Environment]::NewLine+[Environment]::NewLine+'接下来会打开“检查并修复”。'
    try{Add-Type -AssemblyName PresentationFramework;[void][Windows.MessageBox]::Show($message,'AC8 Integrated')}catch{}
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Action','Repair')
    exit 1
   }
   Start-AC8Launcher $package
   exit 0
  }
  'Update'{
   Write-Host 'AC8 Integrated · 检查更新（GitHub 发布页，只下载、不上传任何数据）'
   $state=Read-AC8AppState $installRoot
   Write-Host ('当前版本：'+$state.current)
   $busy=Get-AC8AppBusyReason $installRoot;if($busy){Stop-AC8App 'APP_BUSY' $busy}
   $offer=Get-AC8UpdateOffer $installRoot $Feed
   if((Compare-AC8AppVersion $offer.Version ([string]$state.current)) -le 0){
    Remove-AC8Tree $offer.Cache
    Write-Host ('已是最新版本（GitHub 最新正式版：'+$offer.Version+'）。') -ForegroundColor Green
    if(!$NoLaunch -and $Yes){Start-AC8Launcher (Get-AC8CurrentPackage $installRoot)}
    Wait-AC8Close;exit 0
   }
   Write-Host ('发现新版本：'+$offer.Version) -ForegroundColor Cyan
   if($offer.NotesUrl){Write-Host ('更新说明：'+$offer.NotesUrl)}
   if(!$Yes -and (Read-Host '输入 Y 下载并安装；直接回车取消') -ine 'Y'){Remove-AC8Tree $offer.Cache;Write-Host '已取消，没有任何改动。';exit 0}
   Write-Host '正在下载并校验签名和哈希…'
   $report=@(Install-AC8AppUpdate $installRoot $offer $Feed -NoRegister:$NoRegister)
   Write-AC8Findings $report
   Write-Host ('已更新到 '+$offer.Version+'。设置、键位、附加 Mod 和飞行记录都已保留；需要时可在“检查并修复”中回退到 '+$state.current+'。') -ForegroundColor Green
   if(!$NoLaunch -and ($Yes -or (Read-Host '直接回车打开启动器；输入 N 关闭') -ine 'N')){Start-AC8Launcher (Get-AC8CurrentPackage $installRoot)}
   exit 0
  }
  'Repair'{
   Write-Host 'AC8 Integrated · 检查并修复'
   $findings=@(Invoke-AC8AppRepair $installRoot -Feed $Feed -NoRegister:$NoRegister)
   Write-AC8Findings $findings
   $option='"'+[IO.Path]::Combine($installRoot,'Start-AC8-From-Steam.cmd')+'" %command%'
   if(@($findings | Where-Object {$_.Item -eq 'Steam 启动选项' -and $_.Status -eq 'problem'}).Count){try{Set-Clipboard -Value $option;Write-Host '启动选项已复制到剪贴板。' -ForegroundColor Cyan}catch{}}
   $bad=@($findings | Where-Object {$_.Status -eq 'problem'}).Count
   Write-Host $(if($bad){'检查完成：'+$bad+' 项需要处理，见上方说明。'}else{'检查完成，没有需要处理的问题。'})
   if($Yes){exit $(if($bad){1}else{0})}
   $state=Read-AC8AppState $installRoot;$previous=[string]$state.previous
   $prompt='直接回车打开启动器'+$(if($previous){'；输入 R 回退到上一版本 '+$previous}else{''})+'；输入 Q 关闭'
   $answer=Read-Host $prompt
   if($previous -and $answer -ieq 'R'){
    Write-AC8Findings @(Invoke-AC8AppRollback $installRoot -NoRegister:$NoRegister)
    Write-Host ('已回退到 '+$previous+'。') -ForegroundColor Green;$answer=Read-Host '直接回车打开启动器；输入 Q 关闭'
   }
   if($answer -ine 'Q' -and !$NoLaunch){Start-AC8Launcher (Get-AC8CurrentPackage $installRoot)}
   exit $(if($bad){1}else{0})
  }
  'Rollback'{
   $state=Read-AC8AppState $installRoot
   if(!$Yes -and (Read-Host ('输入 Y 从 '+$state.current+' 回退到 '+$state.previous+'；直接回车取消')) -ine 'Y'){exit 0}
   Write-AC8Findings @(Invoke-AC8AppRollback $installRoot -NoRegister:$NoRegister)
   Write-Host ('已回退到 '+$state.previous+'。') -ForegroundColor Green
   Wait-AC8Close;exit 0
  }
  'Uninstall'{
   Write-Host '卸载 AC8 Integrated'
   if(!$Yes -and (Read-Host '输入 Y 确认卸载；直接回车取消') -ine 'Y'){Write-Host '已取消。';exit 0}
   $keep=!$RemoveData
   if(!$Yes){$keep=(Read-Host 'data 文件夹保存着设置、键位、附加 Mod、飞行记录和每次启动前的存档备份。直接回车保留；输入 D 一并删除') -ine 'D'}
   $option='"'+[IO.Path]::Combine($installRoot,'Start-AC8-From-Steam.cmd')+'" %command%'
   Set-Location -LiteralPath ([IO.Path]::GetTempPath())
   Invoke-AC8AppUninstall $installRoot $keep -NoRegister:$NoRegister
   Write-Host '已卸载 AC8 Integrated。游戏目录保持原版。' -ForegroundColor Green
   Write-Host ('最后一步：到 Steam → AC8 → 属性 → 通用 → 启动选项，删除 '+$option) -ForegroundColor Yellow
   if($keep){Write-Host ('已保留玩家数据：'+[IO.Path]::Combine($installRoot,'data'))}
   Wait-AC8Close;exit 0
  }
  'Status'{
   $state=Read-AC8AppState $installRoot
   ConvertTo-Json -InputObject ([pscustomobject]@{installRoot=$installRoot;current=$state.current;previous=$state.previous;installed=@(Get-AC8InstalledVersions $installRoot)}) | Write-Output
   exit 0
  }
 }
}catch{
 $code=[string]$_.Exception.Data['AC8Code']
 Write-Host ('[未完成] '+$_.Exception.Message+$(if($code){' ['+$code+']'}else{''})) -ForegroundColor Red
 $hint=[string]$_.Exception.Data['AC8Hint'];if($hint){Write-Host $hint -ForegroundColor Yellow}
 if($Action -in @('Update','Repair','Rollback','Uninstall')){Wait-AC8Close}
 exit 1
}
