@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
if "%~1"=="--test" goto test
echo Tests state transitions, setup, and IPC without changing devices or services.
echo Usage: tests\test.cmd --test
echo Set MWS_CSC for the compiler and MWS_AHK for AutoHotkey64.exe.
if "%~1"=="--help" exit /b 0
exit /b 64
:test
if not "%~2"=="" exit /b 64
if not defined MWS_CSC set "MWS_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
set "workRoot=%TEMP%\codex"
if defined AGENTS_TEMP if exist "%AGENTS_TEMP%\" set "workRoot=%AGENTS_TEMP%"
set "workDir=!workRoot!\Codex_mouse-wake-suppressor_tests"
if not exist "!workDir!\" mkdir "!workDir!" || exit /b 74
set "MWS_TEST_EXE=!workDir!\__tests.exe"
pushd "%~dp0..\src" || exit /b 74
"%MWS_CSC%" /nologo /target:exe /out:"!MWS_TEST_EXE!" /main:MouseWakeSuppressor.Tests /reference:System.dll,System.Core.dll Core.cs WindowsPlatform.cs Ipc.cs LockDisplay.cs LockNative.cs LockDisplayHost.cs LockInputHelper.cs ..\tests\Tests.cs > "!workDir!\build.log" 2>&1
if not "!errorlevel!"=="0" (
    type "!workDir!\build.log" 1>&2
    popd
    exit /b 65
)
"!MWS_TEST_EXE!" --test
if not "!errorlevel!"=="0" goto failed
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ..\tests\Tests.Setup.ps1 -WorkDir "!workDir!"
if not "!errorlevel!"=="0" goto failed
if defined MWS_AHK (
    "%MWS_AHK%" /ErrorStdOut=UTF-8 /Validate MouseWakeSuppressor.ahk
    if not "!errorlevel!"=="0" goto failed
    "%MWS_AHK%" /ErrorStdOut=UTF-8 ..\tests\Tests.ahk --test
    if not "!errorlevel!"=="0" goto failed
)
popd
exit /b 0
:failed
popd
exit /b 1
