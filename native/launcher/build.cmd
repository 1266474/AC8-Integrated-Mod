@echo off
rem Builds native\build\AC8 Integrated.exe (Windows subsystem, static CRT, no debug information).
cd /d "%~dp0"
if not defined VSCMD_ARG_TGT_ARCH (
 for /f "usebackq delims=" %%I in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "AC8_VS_PATH=%%I"
 if not defined AC8_VS_PATH exit /b 1
)
if not defined VSCMD_ARG_TGT_ARCH call "%AC8_VS_PATH%\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
if /i not "%VSCMD_ARG_TGT_ARCH%"=="x64" exit /b 1
if not exist ..\build mkdir ..\build
python -X utf8 version-header.py ..\build\launcher-version.h
if errorlevel 1 exit /b 1
rc /nologo /I ..\build /fo ..\build\AC8-Launcher.res AC8-Launcher.rc
if errorlevel 1 exit /b 1
cl /nologo /std:c++20 /utf-8 /EHsc /MT /O2 /DUNICODE /D_UNICODE AC8-Launcher.cpp /Fo..\build\AC8-Launcher.obj /Fe"..\build\AC8 Integrated.exe" /link ..\build\AC8-Launcher.res /SUBSYSTEM:WINDOWS /MANIFEST:NO user32.lib gdi32.lib shell32.lib
exit /b %errorlevel%
