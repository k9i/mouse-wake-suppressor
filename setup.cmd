@echo off
setlocal DisableDelayedExpansion
if not [%2]==[] goto usage
if "%~1"=="--help" goto help
if "%~1"=="install" goto run
if "%~1"=="status" goto run
if "%~1"=="uninstall" goto run
:usage
call :help
exit /b 64
:help
echo Mouse Wake Suppressor setup
echo:
echo Usage:
echo   setup.cmd ^<command^>
echo:
echo Commands:
echo   install     Install or update files, then start the service.
echo   status      Show service registration and required files.
echo   uninstall   Remove service registration; keep files and settings.
echo   --help      Show this help.
echo:
echo Install from the repository:
echo   1. Run: build.cmd --build
echo   2. Open an administrator terminal.
echo   3. Run: setup.cmd install
echo   Build output: dist, or the directory set by MWS_BUILD_DIR.
echo   Optional initial INI: set MWS_CONFIG_SOURCE to its full path.
echo:
echo Permissions:
echo   install and uninstall require an administrator terminal.
echo   status and --help can run as a normal user.
echo:
echo Default folder:
echo   C:\Program Files\MouseWakeSuppressor
echo   Uses ProgramW6432, or ProgramFiles when ProgramW6432 is undefined.
echo:
echo Requires Windows PowerShell.
echo Elevation, builds, and rollback must be handled manually.
echo:
exit /b 0
:run
set "MWS_SETUP_FILE=%~f0"
set "MWS_SETUP_ACTION=%~1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "$body = [IO.File]::ReadAllText($env:MWS_SETUP_FILE); & ([scriptblock]::Create($body.Substring($body.IndexOf('#' + ' MWS_SETUP_POWERSHELL'))))"
exit /b %errorlevel%
# MWS_SETUP_POWERSHELL
$ErrorActionPreference = 'Stop'
$serviceName = 'MouseWakeSuppressor'
$source = Split-Path -LiteralPath $env:MWS_SETUP_FILE
$programFiles = $env:ProgramW6432
if (-not $programFiles) { $programFiles = $env:ProgramFiles }
$target = if ($programFiles) { Join-Path $programFiles $serviceName } else { $null }
$files = @('MouseWakeSuppressorService.exe', 'MouseWakeSuppressor.ahk', 'MwsClient.ahk', 'MwsView.ahk', 'setup.cmd')
$scExe = Join-Path $env:SystemRoot 'System32\sc.exe'

# Resolve repository inputs separately from the installed, flat layout.
function Get-SourceFile([string] $Name) {
    if ([string]::Equals([IO.Path]::GetFullPath($source).TrimEnd('\'), [IO.Path]::GetFullPath($target).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $source $Name
    }
    if ($Name -eq 'setup.cmd') { return Join-Path $source $Name }
    if ($Name -eq 'MouseWakeSuppressorService.exe') {
        $buildDir = if ($env:MWS_BUILD_DIR) { $env:MWS_BUILD_DIR } else { Join-Path $source 'dist' }
        return Join-Path $buildDir $Name
    }
    return Join-Path (Join-Path $source 'src') $Name
}

# Capture native exit codes even when a CLI writes diagnostics to stderr.
function Invoke-Native([string] $File, [string[]] $Arguments) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $File @Arguments 2>&1
        $succeeded = $?
        $code = $LASTEXITCODE
        if (-not $succeeded -and -not $code) { $code = 74 }
    } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ Code = $code; Text = ($output | Out-String).TrimEnd() }
}

# Keep all SCM operations on the standard Windows CLI.
function Invoke-Sc([string[]] $Arguments) {
    return Invoke-Native $scExe $Arguments
}

# Reject failed queries instead of interpreting them as an absent service.
function Get-ServiceState {
    $result = Invoke-Sc @('query', $serviceName)
    if ($result.Code -eq 1060) { return 0 }
    if ($result.Code -ne 0) { throw "sc query failed ($($result.Code)): $($result.Text)" }
    # Numeric SCM states are independent of the display language; TYPE is 10.
    if ($result.Text -notmatch '(?m)^\s*[^:\r\n]+:\s*([1-7])\s+\S+') { throw 'Cannot read service state.' }
    return [int] $Matches[1]
}

# Read ImagePath without relying on localized sc qc field labels.
function Get-RegisteredExecutable {
    $raw = (Get-ItemProperty -LiteralPath "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$serviceName" -Name ImagePath).ImagePath
    $raw = [Environment]::ExpandEnvironmentVariables($raw).Trim()
    if ($raw -match '^"([^"]+\.exe)"(?:\s.*)?$') { return [IO.Path]::GetFullPath($Matches[1]) }
    if ($raw -match '^(.+?\.exe)(?:\s.*)?$') { return [IO.Path]::GetFullPath($Matches[1]) }
    throw 'Cannot read the registered executable path.'
}

# Mutating commands require an already elevated terminal.
function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw [UnauthorizedAccessException]::new('Run this command from an administrator terminal.')
    }
}

# Monotonic time prevents wall clock adjustments from extending deadlines.
function Get-Milliseconds { return [Environment]::TickCount -band 0xffffffffL }
function Wait-Poll { Start-Sleep -Milliseconds 250 }

# Never update binaries while service shutdown and recovery are still running.
function Wait-ServiceState([int] $Expected, [int] $TimeoutMs) {
    $started = Get-Milliseconds
    while ($true) {
        $state = Get-ServiceState
        if ($state -eq $Expected) { return }
        if ($state -eq 0) { throw 'Service registration disappeared while waiting.' }
        if (((Get-Milliseconds) - $started + 4294967296) % 4294967296 -ge $TimeoutMs) {
            throw "Timed out after $TimeoutMs ms waiting for SCM state $Expected (last state: $state)."
        }
        Wait-Poll
    }
}

# Grant read/write to the INI only, without delete or directory write access.
function Set-IniPermissions([string] $Path) {
    $result = Invoke-Native (Join-Path $env:SystemRoot 'System32\icacls.exe') @($Path, '/grant:r', '*S-1-5-32-545:(R,W)')
    if ($result.Code -ne 0) { throw "INI ACL update failed ($($result.Code)): $($result.Text)" }
}

# Display the actual remaining registration and files, including after a failure.
function Show-Status {
    foreach ($command in @('query', 'qc')) {
        $result = Invoke-Sc @($command, $serviceName)
        Write-Host $result.Text
        if ($result.Code -ne 0 -and $result.Code -ne 1060) { throw "sc $command failed ($($result.Code))." }
    }
    foreach ($name in ($files + 'mws_config.ini')) {
        $path = Join-Path $target $name
        Write-Host ("{0}: {1}" -f $(if (Test-Path -LiteralPath $path -PathType Leaf) { 'Present' } else { 'Missing' }), $path)
    }
}

# Installation deliberately leaves failed updates in place for explicit recovery.
function Invoke-Setup {
    $stage = 'initialization'
    try {
        if (-not $target) { throw 'Neither ProgramW6432 nor ProgramFiles is defined.' }
        if ($env:MWS_SETUP_ACTION -eq 'status') { Show-Status; return 0 }
        Assert-Administrator
        if ($env:MWS_SETUP_ACTION -eq 'uninstall') {
            $stage = 'uninstall'
            if ((Get-ServiceState) -eq 0) { Write-Host 'Service is not registered. Files are retained.'; return 0 }
            $registered = Get-RegisteredExecutable
            if (-not (Test-Path -LiteralPath $registered -PathType Leaf)) { throw "Registered executable is missing: $registered" }
            $result = Invoke-Native $registered @('-uninstall')
            Write-Host $result.Text
            if ($result.Code -ne 0) { throw "Registered executable -uninstall failed ($($result.Code)). Registration may remain." }
            if ((Get-ServiceState) -ne 0) { throw 'Service registration remains after uninstall.' }
            Write-Host 'Registration removed. Deployment files, INI, and recovery records are retained.'
            return 0
        }
        $stage = 'source preflight (service has not been stopped)'
        foreach ($name in $files) {
            if (-not (Test-Path -LiteralPath (Get-SourceFile $name) -PathType Leaf)) {
                throw "Required source file is missing: $name. Run build.cmd --build manually if needed."
            }
        }
        if ($env:MWS_CONFIG_SOURCE -and -not (Test-Path -LiteralPath (Join-Path $target 'mws_config.ini') -PathType Leaf) -and
            -not (Test-Path -LiteralPath $env:MWS_CONFIG_SOURCE -PathType Leaf)) {
            throw 'MWS_CONFIG_SOURCE does not point to an existing INI file.'
        }
        $expected = [IO.Path]::GetFullPath((Join-Path $target $files[0]))
        $state = Get-ServiceState
        if ($state -ne 0) {
            $stage = 'registered path check (service has not been stopped)'
            $registered = Get-RegisteredExecutable
            if (-not [string]::Equals($registered, $expected, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Service is registered at $registered. Uninstall the old registration first; no files were moved."
            }
            $stage = 'service stop'
            if ($state -eq 2) { Wait-ServiceState 4 30000; $state = Get-ServiceState }
            if ($state -ne 1 -and $state -ne 3) {
                $result = Invoke-Sc @('stop', $serviceName)
                if ($result.Code -ne 0 -and $result.Code -ne 1062) { throw "sc stop failed ($($result.Code)): $($result.Text)" }
            }
            Wait-ServiceState 1 600000
        }
        $stage = 'file deployment (existing registration is retained)'
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { New-Item -ItemType Directory -Path $target | Out-Null }
        if (-not [string]::Equals([IO.Path]::GetFullPath($source).TrimEnd('\'), [IO.Path]::GetFullPath($target).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($name in $files) { Copy-Item -LiteralPath (Get-SourceFile $name) -Destination (Join-Path $target $name) -Force }
        }
        $ini = Join-Path $target 'mws_config.ini'
        if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
            $sourceIni = $env:MWS_CONFIG_SOURCE
            if ($sourceIni) { Copy-Item -LiteralPath $sourceIni -Destination $ini }
            else { [IO.File]::WriteAllBytes($ini, [byte[]]@()) }
        }
        $stage = 'INI permissions (service has not been started)'
        Set-IniPermissions $ini
        $stage = 'service registration/start'
        if ($state -eq 0) {
            $result = Invoke-Native $expected @('-install')
        } else {
            $result = Invoke-Sc @('start', $serviceName)
        }
        Write-Host $result.Text
        if ($result.Code -ne 0) { throw "Service registration/start failed ($($result.Code))." }
        Wait-ServiceState 4 30000
        Write-Host "Installed and running: $target"
        return 0
    } catch {
        $code = if ($_.Exception -is [UnauthorizedAccessException]) { 77 } else { 74 }
        [Console]::Error.WriteLine("Failed during $stage : $($_.Exception.Message)")
        [Console]::Error.WriteLine('No rollback was performed. Files and recovery records are retained; inspect the state below before retrying.')
        try { Show-Status } catch { [Console]::Error.WriteLine("Status unavailable: $($_.Exception.Message)") }
        return $code
    }
}
exit (Invoke-Setup)
