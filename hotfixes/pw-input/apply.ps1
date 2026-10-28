[CmdletBinding()]
param(
 [string]$PackageRoot = (Join-Path $env:LOCALAPPDATA 'Programs\AC8 Integrated\versions\2.5.2'),
 [string]$ModsRoot = (Join-Path $env:LOCALAPPDATA 'Programs\AC8 Integrated\data\ue4ss-mods'),
 [string]$PythonExecutable = 'python.exe',
 [switch]$PrepareOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$taskWorkspace = $PSScriptRoot
if (Get-Process -Name AceCombat8 -ErrorAction SilentlyContinue) {
 throw 'Close AceCombat8 and wait for launcher cleanup before applying this local hotfix.'
}
$taskPython = (Get-Command $PythonExecutable -ErrorAction Stop).Source
function Invoke-HotfixPython([string[]]$Arguments, [int[]]$AcceptedExitCodes = @(0)) {
 $taskOutput = (& $taskPython @Arguments 2>&1 | Out-String)
 if ($AcceptedExitCodes -notcontains $LASTEXITCODE) { throw $taskOutput.Trim() }
 Write-Host $taskOutput.Trim()
 return ($taskOutput | ConvertFrom-Json)
}
$taskNativeArguments = @((Join-Path $taskWorkspace 'tools\deploy_native.py'))
$taskNativeOptions = @('--workspace', $taskWorkspace, '--install-root', $PackageRoot)
$taskRailArguments = @((Join-Path $taskWorkspace 'tools\patch_railgun.py'))
$taskRailOptions = @('--workspace', $taskWorkspace, '--mods-root', $ModsRoot)
$taskRecord = Join-Path $taskWorkspace 'results\native-deployment.json'
$taskNativeAlreadyApplied = $false
if (Test-Path -LiteralPath $taskRecord) {
 $taskState = Get-Content -LiteralPath $taskRecord -Raw -Encoding UTF8 | ConvertFrom-Json
 $taskNativeAlreadyApplied = $taskState.status -eq 'applied'
}
# Stage PW artifacts and verify both sides before changing either installed Mod.
$taskRailBefore = Invoke-HotfixPython -Arguments ($taskRailArguments + @('check') + $taskRailOptions) -AcceptedExitCodes @(0, 1)
if (@($taskRailBefore.files | Where-Object { $_.state -eq 'original' }).Count -gt 0 -and
    @($taskRailBefore.files | Where-Object { $_.state -eq 'patched' }).Count -gt 0) {
 throw 'PW targets are in mixed original/patched states; restore or finish the existing PW operation first.'
}
$null = Invoke-HotfixPython ($taskRailArguments + @('prepare') + $taskRailOptions)
if ($taskNativeAlreadyApplied) {
 $null = Invoke-HotfixPython ($taskNativeArguments + @('check') + $taskNativeOptions)
} else {
 $null = Invoke-HotfixPython ($taskNativeArguments + @('prepare') + $taskNativeOptions)
}
if ($PrepareOnly) {
 Write-Host 'PREPARED: installed Mod files have not been changed.'
 return
}
$taskNativeNew = $false
$taskRailNew = $false
try {
 $taskNativeResult = Invoke-HotfixPython ($taskNativeArguments + @('apply') + $taskNativeOptions)
 $taskNativeNew = $taskNativeResult.status -eq 'applied'
 $taskRailResult = Invoke-HotfixPython ($taskRailArguments + @('apply') + $taskRailOptions)
 $taskRailNew = $taskRailResult.updated -gt 0
 $null = Invoke-HotfixPython ($taskNativeArguments + @('check') + $taskNativeOptions)
 $null = Invoke-HotfixPython ($taskRailArguments + @('check') + $taskRailOptions)
 Write-Host 'APPLIED: local native and PW-MkI hotfixes verified. Start through your existing offline launcher.'
} catch {
 $taskFailure = $_
 if ($taskRailNew) {
  try {
   $null = Invoke-HotfixPython ($taskRailArguments + @('rollback') + $taskRailOptions)
   Write-Warning 'The new PW deployment was rolled back because the combined operation failed.'
  } catch {
   Write-Warning ('Automatic PW rollback requires attention: ' + $_.Exception.Message)
  }
 }
 if ($taskNativeNew) {
  try {
   $null = Invoke-HotfixPython ($taskNativeArguments + @('rollback') + $taskNativeOptions)
   Write-Warning 'The new native deployment was rolled back because the combined operation failed.'
  } catch {
   Write-Warning ('Automatic native rollback requires attention: ' + $_.Exception.Message)
  }
 }
 throw $taskFailure
}
