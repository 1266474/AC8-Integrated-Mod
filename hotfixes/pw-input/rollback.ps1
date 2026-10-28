[CmdletBinding()]
param(
 [string]$PackageRoot = (Join-Path $env:LOCALAPPDATA 'Programs\AC8 Integrated\versions\2.5.2'),
 [string]$ModsRoot = (Join-Path $env:LOCALAPPDATA 'Programs\AC8 Integrated\data\ue4ss-mods'),
 [string]$PythonExecutable = 'python.exe'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskWorkspace = $PSScriptRoot
if (Get-Process -Name AceCombat8 -ErrorAction SilentlyContinue) {
 throw 'Close AceCombat8 and wait for launcher cleanup before rolling back.'
}
$taskPython = (Get-Command $PythonExecutable -ErrorAction Stop).Source
function Invoke-HotfixPython([string[]]$Arguments) {
 $taskOutput = (& $taskPython @Arguments 2>&1 | Out-String)
 if ($LASTEXITCODE -ne 0) { throw $taskOutput.Trim() }
 Write-Host $taskOutput.Trim()
 return ($taskOutput | ConvertFrom-Json)
}
$taskNativeArguments = @((Join-Path $taskWorkspace 'tools\deploy_native.py'))
$taskNativeOptions = @('--workspace', $taskWorkspace, '--install-root', $PackageRoot)
$taskRailArguments = @((Join-Path $taskWorkspace 'tools\patch_railgun.py'))
$taskRailOptions = @('--workspace', $taskWorkspace, '--mods-root', $ModsRoot)
$taskNativeRecord = Join-Path $taskWorkspace 'results\native-deployment.json'
$taskRailRecord = Join-Path $taskWorkspace 'backups\railgun\manifest.json'
# Preflight every recorded native file first. Unknown installed changes abort
# before either subsystem is modified; each Python tool also checks backups.
if (Test-Path -LiteralPath $taskNativeRecord) {
 $null = Invoke-HotfixPython ($taskNativeArguments + @('check') + $taskNativeOptions)
}
if (Test-Path -LiteralPath $taskRailRecord) {
 # prepare accepts both pinned states, verifies originals, and never changes
 # installed files. It rejects unknown targets before native rollback starts.
 $null = Invoke-HotfixPython ($taskRailArguments + @('prepare') + $taskRailOptions)
}
if (Test-Path -LiteralPath $taskNativeRecord) {
 $null = Invoke-HotfixPython ($taskNativeArguments + @('rollback') + $taskNativeOptions)
}
if (Test-Path -LiteralPath $taskRailRecord) {
 $null = Invoke-HotfixPython ($taskRailArguments + @('rollback') + $taskRailOptions)
}
Write-Host 'ROLLED BACK: recorded original files restored; unrecognized changes are never overwritten.'
