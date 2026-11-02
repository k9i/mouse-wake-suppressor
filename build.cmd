@echo off
setlocal EnableDelayedExpansion
if "%~1"=="--build" goto build
echo Builds the Mouse Wake Suppressor service.
echo Usage: build.cmd --build
echo Set MWS_CSC for the compiler and MWS_BUILD_DIR for the output directory.
if "%~1"=="--help" exit /b 0
exit /b 64
:build
if not "%~2"=="" exit /b 64
if not defined MWS_CSC set "MWS_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%MWS_CSC%" (
    echo The .NET Framework compiler was not found. 1>&2
    exit /b 69
)
set "workRoot=%TEMP%\codex"
if defined AGENTS_TEMP if exist "%AGENTS_TEMP%\" set "workRoot=%AGENTS_TEMP%"
set "workDir=!workRoot!\Codex_mouse-wake-suppressor_build"
if not exist "!workDir!\" mkdir "!workDir!" || exit /b 74
if not defined MWS_BUILD_DIR set "MWS_BUILD_DIR=%~dp0dist"
if not exist "%MWS_BUILD_DIR%\" mkdir "%MWS_BUILD_DIR%" || exit /b 74
pushd "%~dp0src" || exit /b 74
"%MWS_CSC%" /nologo /target:exe /out:"%MWS_BUILD_DIR%\MouseWakeSuppressorService.exe" /reference:System.ServiceProcess.dll,System.dll,System.Core.dll,System.Configuration.Install.dll MouseWakeSuppressorService.cs Core.cs WindowsPlatform.cs Ipc.cs LockDisplay.cs LockNative.cs LockDisplayHost.cs LockInputHelper.cs > "!workDir!\build.log" 2>&1
if not "!errorlevel!"=="0" (
    type "!workDir!\build.log" 1>&2
    popd
    exit /b 65
)
popd
echo Build completed.
exit /b 0
