@echo off
setlocal EnableDelayedExpansion
set DIR=%~dp0
set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" (
    echo ERROR: .NET Framework 4 compiler not found: %CSC%
    echo Please install .NET Framework 4.x and retry.
    exit /b 1
)
"%CSC%" /target:exe /out:"%DIR%MouseWakeSuppressorService.exe" /reference:System.ServiceProcess.dll,System.dll,System.Configuration.Install.dll,System.Windows.Forms.dll,System.Drawing.dll "%DIR%MouseWakeSuppressorService.cs"
set BUILD_EXIT=!ERRORLEVEL!
if !BUILD_EXIT! neq 0 (
    echo BUILD FAILED - exit code !BUILD_EXIT!
    exit /b !BUILD_EXIT!
)
echo BUILD SUCCEEDED: %DIR%MouseWakeSuppressorService.exe
endlocal
