[CmdletBinding()]
param([string]$PythonExecutable='python.exe')
$ErrorActionPreference='Stop'
& $PythonExecutable (Join-Path $PSScriptRoot 'tools\deploy_revision2.py') rollback
if($LASTEXITCODE -ne 0){throw 'Revision 2 rollback refused; inspect the deployment record before proceeding.'}
Write-Host 'Revision 1 restored. To also remove revision 1, run rollback.ps1 next.'
