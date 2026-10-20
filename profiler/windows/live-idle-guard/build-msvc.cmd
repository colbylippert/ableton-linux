@echo off
rem build-msvc.cmd: build live-idle-guard.exe with Visual Studio's C++ compiler (x64, static runtime), on Windows.
rem Usage: profiler\windows\live-idle-guard\build-msvc.cmd [OUT_DIR]   (default: this directory; the .exe is not tracked)
rem build.sh is the same build with mingw-w64 from Linux.
setlocal
set "HERE=%~dp0"
set "OUT=%~1"
if "%OUT%"=="" set "OUT=%HERE:~0,-1%"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS (
  echo build-msvc.cmd: no Visual Studio with the C++ tools
  exit /b 1
)
rem no VS telemetry helper (vctip.exe): it outlives the build and holds a caller's output pipe open
set VSCMD_SKIP_SENDTELEMETRY=1
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cl /nologo /O2 /W4 /EHsc /MT /DUNICODE /D_UNICODE /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\live-idle-guard.exe" "%HERE%live-idle-guard.cpp" powrprof.lib advapi32.lib || exit /b 1
del "%OUT%\live-idle-guard.obj" 2>nul
echo built %OUT%\live-idle-guard.exe
