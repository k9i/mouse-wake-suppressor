@echo off
setlocal EnableDelayedExpansion
if "%~1"=="--build" goto build
echo Builds the Mouse Wake Suppressor service.
echo Usage: build.cmd --build
echo Set the compiler path with the MWS_CSC environment variable.
if "%~1"=="--help" exit /b 0
exit /b 64
:build
if not "%~2"=="" exit /b 64
if not defined MWS_CSC set "MWS_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%MWS_CSC%" (
    echo The .NET Framework compiler was not found. 1>&2
    exit /b 69
)
pushd "%~dp0" || exit /b 74
"%MWS_CSC%" /nologo /target:exe /out:MouseWakeSuppressorService.exe /reference:System.ServiceProcess.dll,System.dll,System.Core.dll,System.Configuration.Install.dll MouseWakeSuppressorService.cs Core.cs WindowsPlatform.cs Ipc.cs > __build.log 2>&1
if not "!errorlevel!"=="0" (
    type __build.log 1>&2
    popd
    exit /b 65
)
popd
echo Build completed.
exit /b 0
