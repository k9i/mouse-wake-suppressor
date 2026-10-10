@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
if "%~1"=="--test" goto test
echo Tests state transitions and IPC without changing devices.
echo Usage: test.cmd --test
echo Set MWS_CSC for the compiler and MWS_AHK for AutoHotkey64.exe.
if "%~1"=="--help" exit /b 0
exit /b 64
:test
if not "%~2"=="" exit /b 64
if not defined MWS_CSC set "MWS_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
pushd "%~dp0" || exit /b 74
"%MWS_CSC%" /nologo /target:exe /out:__tests.exe /main:MouseWakeSuppressor.Tests /reference:System.dll,System.Core.dll Core.cs WindowsPlatform.cs Ipc.cs LockDisplay.cs LockNative.cs LockDisplayHost.cs LockInputHelper.cs Tests.cs > __test_build.log 2>&1
if not "!errorlevel!"=="0" (
    type __test_build.log 1>&2
    popd
    exit /b 65
)
__tests.exe --test
if not "!errorlevel!"=="0" (
    popd
    exit /b 1
)
if defined MWS_AHK (
    "%MWS_AHK%" /ErrorStdOut=UTF-8 /Validate setup.ahk
    if not "!errorlevel!"=="0" (
        popd
        exit /b 1
    )
    "%MWS_AHK%" /ErrorStdOut=UTF-8 /Validate MouseWakeSuppressor.ahk
    if not "!errorlevel!"=="0" (
        popd
        exit /b 1
    )
    "%MWS_AHK%" /ErrorStdOut=UTF-8 Tests.ahk --test
    if not "!errorlevel!"=="0" (
        popd
        exit /b 1
    )
)
popd
exit /b 0
