param([string]$Compiler='cl.exe')
$ErrorActionPreference='Stop'
$taskRoot=Split-Path -Parent $PSScriptRoot
$taskNative=[IO.Path]::GetFullPath((Join-Path $taskRoot '..\..\native'))
$taskBuild=Join-Path $taskNative 'build'
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
$taskSource=Join-Path $taskNative 'src\mouse_aim.cpp'
$taskText=[IO.File]::ReadAllText($taskSource)
$taskRaw=[regex]::Match($taskText,'(?s)UINT WINAPI capture_get_raw_input_data\(.*?\r?\nbool prepare_raw_input_capture\(').Value
if(-not $taskRaw -or $taskRaw -match 'target_mutex'){throw 'Raw Input still depends on the controller mutex'}
if($taskRaw -notmatch '(?s)input_generation=mouse_delta\.token\(\);.*original_get_raw_input_data\('){throw 'Raw Input must capture generation before reading the packet'}
$taskDirect=[regex]::Match($taskText,'(?s)if\(!raw_input_hooked\.load\(\).*?rate_input_poll\.fetch_add').Value
if(-not $taskDirect -or $taskDirect -match 'target_mutex'){throw 'DirectInput still depends on the controller mutex'}
if($taskDirect -notmatch '(?s)input_generation=mouse_delta\.token\(\);.*GetDeviceState\('){throw 'DirectInput must capture generation before reading its state'}
if($taskText -notmatch 'independent_mouse=false;'){throw 'Expected game-frame input consumption was changed'}
$taskExe=Join-Path $taskBuild 'native-input-tests.exe'
$taskObject=Join-Path $taskBuild 'native-input-tests.obj'
$taskTest=Join-Path $taskNative 'input_inbox_tests.cpp'
& $Compiler /nologo /std:c++20 /EHsc /MD /O2 $taskTest "/Fo$taskObject" "/Fe$taskExe"
if($LASTEXITCODE -ne 0){throw "Native test compilation failed: $LASTEXITCODE"}
& $taskExe
if($LASTEXITCODE -ne 0){throw "Native tests failed: $LASTEXITCODE"}
Write-Output 'PASS Raw Input/DirectInput controller-lock separation and game-frame-consumption source contract'
