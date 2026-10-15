@echo off
rem Builds native\build\AC8 Integrated.exe with the .NET Framework 4 C# compiler included in Windows (no Visual Studio
rem needed). It references the Windows PowerShell 5.1 engine (System.Management.Automation) of this machine.
cd /d "%~dp0"
if not exist ..\build mkdir ..\build
python -X utf8 assembly-info.py ..\build\LauncherVersion.cs
if errorlevel 1 exit /b 1
set "AC8_SMA="
for /f "usebackq delims=" %%I in (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "[PSObject].Assembly.Location"`) do set "AC8_SMA=%%I"
if not defined AC8_SMA exit /b 1
"%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:anycpu /optimize+ /debug- /codepage:65001 /win32icon:..\..\package-template\app\AC8.ico /win32manifest:AC8-Launcher.manifest /reference:"%AC8_SMA%" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /out:"..\build\AC8 Integrated.exe" AC8-Launcher.cs ..\build\LauncherVersion.cs
exit /b %errorlevel%
