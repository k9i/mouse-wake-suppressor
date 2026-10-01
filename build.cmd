@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion
if "%~1"=="--build" goto build
echo Mouse Wake Suppressor のサービスを build します。
echo 使い方: build.cmd --build
echo compiler は環境変数 MWS_CSC で変更できます。
if "%~1"=="--help" exit /b 0
exit /b 64
:build
if not "%~2"=="" exit /b 64
if not defined MWS_CSC set "MWS_CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%MWS_CSC%" (
    echo .NET Framework compiler が見つかりません。 1>&2
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
echo build が完了しました。
exit /b 0
