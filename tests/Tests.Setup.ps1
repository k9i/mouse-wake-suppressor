param([Parameter(Mandatory=$true)][string] $WorkDir)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1')
$root = Join-Path $WorkDir ('setup ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$setup = Join-Path $PSScriptRoot '..\setup.cmd'
$body = [IO.File]::ReadAllText($setup)
$marker = '#' + ' MWS_SETUP_POWERSHELL'
$script = $body.Substring($body.IndexOf($marker)).Replace('exit (Invoke-Setup)', '')
$env:MWS_SETUP_FILE = $setup
. ([scriptblock]::Create($script))
$productionSc = ${function:Invoke-Sc}
$productionNative = ${function:Invoke-Native}
$productionAcl = ${function:Set-IniPermissions}
$productionPath = ${function:Get-RegisteredExecutable}
$productionAdmin = ${function:Assert-Administrator}
$checks = 0

# Tests replace only OS boundaries; deployment and deadline code is unchanged.
function Check($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Reset-Fixture {
    $script:source = Join-Path $root ([guid]::NewGuid().ToString('N') + ' source space')
    $script:target = Join-Path $root ([guid]::NewGuid().ToString('N') + ' Program Files')
    New-Item -ItemType Directory -Path $source, $target | Out-Null
    $env:MWS_BUILD_DIR = ''
    $env:MWS_CONFIG_SOURCE = ''
    New-Item -ItemType Directory -Path (Join-Path $source 'src'), (Join-Path $source 'dist') | Out-Null
    foreach ($name in $files) { [IO.File]::WriteAllText((Get-SourceFile $name), 'new') }
    $script:registered = Join-Path $target $files[0]
    $script:mockState = 4
    $script:clock = 0
    $script:trace = New-Object 'Collections.Generic.List[string]'
    $script:fault = ''
    $script:stage = 'initialization'
    $env:MWS_SETUP_ACTION = 'install'
}
function Assert-Administrator { $trace.Add('admin') }
function Get-RegisteredExecutable { return $registered }
function Get-Milliseconds { return $clock }
function Wait-Poll {
    $script:clock += 250
    if ($fault -ne 'stop-timeout' -and $mockState -eq 3) { $script:mockState = 1 }
    if ($fault -ne 'start-timeout' -and $mockState -eq 2) { $script:mockState = 4 }
}
function Invoke-Sc([string[]] $Arguments) {
    $verb = $Arguments[0]
    if ($verb -ne 'query') { $trace.Add("sc $verb") }
    if ($verb -eq 'stop') {
        if ($fault -eq 'stop') { return [pscustomobject]@{Code=5; Text='stop denied'} }
        $script:mockState = 3
    }
    if ($verb -eq 'start') {
        if ($fault -eq 'start') { return [pscustomobject]@{Code=5; Text='start denied'} }
        $script:mockState = 2
    }
    if ($mockState -eq 0) { return [pscustomobject]@{Code=1060; Text='not registered'} }
    return [pscustomobject]@{Code=0; Text="TYPE : 10 WIN32_OWN_PROCESS`nSTATE : $mockState MOCK"}
}
function Invoke-Native([string] $File, [string[]] $Arguments) {
    $trace.Add("exe $($Arguments[0])")
    if ($fault -eq 'native') { return [pscustomobject]@{Code=74; Text='recovery blocked'} }
    if ($Arguments[0] -eq '-install') { $script:mockState = 4 }
    if ($Arguments[0] -eq '-uninstall') { $script:mockState = 0 }
    return [pscustomobject]@{Code=0; Text='mock executable'}
}
function Set-IniPermissions([string] $Path) {
    $trace.Add('acl')
    if ($fault -eq 'acl') { throw 'ACL denied' }
    Check ($mockState -eq 0 -or $mockState -eq 1) 'ACL must precede service startup.'
}
try {
    Reset-Fixture
    $ini = Join-Path $target 'mws_config.ini'
    [IO.File]::WriteAllText($ini, 'preserved')
    Check ((Invoke-Setup) -eq 0) 'Update failed.'
    Check (($trace -join ',') -eq 'admin,sc stop,acl,sc start') 'Wrong update order.'
    Check ([IO.File]::ReadAllText($ini) -eq 'preserved') 'Existing INI changed.'
    Check ([IO.File]::ReadAllText((Join-Path $target $files[0])) -eq 'new') 'File copy failed.'
    Check ([IO.File]::ReadAllText((Join-Path $target 'MouseWakeSuppressor.ahk')) -eq 'new') 'Source UI was not deployed.'

    Reset-Fixture
    $env:MWS_BUILD_DIR = Join-Path $root 'custom build'
    New-Item -ItemType Directory -Path $env:MWS_BUILD_DIR | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:MWS_BUILD_DIR $files[0]), 'custom')
    Check ((Invoke-Setup) -eq 0) 'Custom build directory install failed.'
    Check ([IO.File]::ReadAllText((Join-Path $target $files[0])) -eq 'custom') 'Build directory override was ignored.'

    Reset-Fixture
    $env:MWS_CONFIG_SOURCE = Join-Path $root 'missing.ini'
    Check ((Invoke-Setup) -ne 0 -and -not $trace.Contains('sc stop')) 'Missing import must fail before stop.'

    Reset-Fixture
    $script:mockState = 0
    [IO.File]::WriteAllText((Join-Path $source 'mws_config.ini'), 'source INI')
    $env:MWS_CONFIG_SOURCE = Join-Path $source 'mws_config.ini'
    Check ((Invoke-Setup) -eq 0) 'New install failed.'
    Check (($trace -join ',') -eq 'admin,acl,exe -install') 'Wrong install order.'
    Check ([IO.File]::ReadAllText((Join-Path $target 'mws_config.ini')) -eq 'source INI') 'Source INI not copied.'

    Reset-Fixture
    $script:mockState = 0
    Check ((Invoke-Setup) -eq 0) 'Empty INI install failed.'
    Check ((Get-Item -LiteralPath (Join-Path $target 'mws_config.ini')).Length -eq 0) 'INI should be empty.'

    Reset-Fixture
    $script:source = $target
    foreach ($name in $files) { [IO.File]::WriteAllText((Join-Path $target $name), 'installed') }
    $script:mockState = 0
    Check ((Invoke-Setup) -eq 0) 'Installed copy re-registration failed.'

    Reset-Fixture
    # A missing source and path mismatch must leave a running service untouched.
    $script:source = Join-Path $root 'missing source'
    Check ((Invoke-Setup) -ne 0) 'Missing source accepted.'
    Check (-not $trace.Contains('sc stop')) 'Stopped before preflight.'
    Reset-Fixture
    $script:registered = 'C:\old path\MouseWakeSuppressorService.exe'
    Check ((Invoke-Setup) -ne 0) 'Mismatched registration accepted.'
    Check (-not $trace.Contains('sc stop')) 'Stopped mismatched service.'

    foreach ($failure in @('stop', 'acl', 'stop-timeout', 'start-timeout', 'start')) {
        Reset-Fixture
        $script:fault = $failure
        Check ((Invoke-Setup) -ne 0) "Failure not propagated: $failure"
        if ($failure -notin @('start-timeout', 'start')) { Check (-not $trace.Contains('sc start')) "Started after failure: $failure" }
        if ($failure -eq 'stop-timeout') {
            Check ($clock -eq 600000) 'Stop deadline differs from ten minutes.'
            Check (-not (Test-Path -LiteralPath (Join-Path $target $files[0]))) 'Copied before shutdown completed.'
        }
        if ($failure -eq 'start-timeout') { Check ($clock -eq 30250) 'Start deadline differs from thirty seconds.' }
    }

    Reset-Fixture
    $env:MWS_SETUP_ACTION = 'uninstall'
    [IO.File]::WriteAllText($registered, 'installed')
    $script:fault = 'native'
    Check ((Invoke-Setup) -ne 0 -and $mockState -eq 4) 'Recovery failure did not retain registration.'
    $script:fault = ''
    Check ((Invoke-Setup) -eq 0 -and $mockState -eq 0) 'Uninstall failed.'
    Check (Test-Path -LiteralPath $registered) 'Uninstall deleted files.'
    Check ((Invoke-Setup) -eq 0) 'Absent service uninstall should succeed.'

    Reset-Fixture
    $env:MWS_SETUP_ACTION = 'status'
    Check ((Invoke-Setup) -eq 0) 'Status failed.'
    Check (-not $trace.Contains('admin')) 'Status requires elevation.'

    # Exercise the real batch launcher in a path containing spaces.
    $launcher = Join-Path $root 'space launcher'
    New-Item -ItemType Directory -Path $launcher | Out-Null
    $copy = Join-Path $launcher 'setup.cmd'
    Copy-Item -LiteralPath $setup -Destination $copy
    foreach ($case in @(@('',64), @('--help',0), @('bad',64), @('install extra',64), @('install ""',64), @('--help extra',64))) {
        & $env:ComSpec /d /c "`"$copy`" $($case[0])" > $null
        Check ($LASTEXITCODE -eq $case[1]) "Batch argument handling failed: $($case[0])"
    }
    $bytes = [IO.File]::ReadAllBytes($setup)
    Check (-not ($bytes | Where-Object { $_ -gt 127 })) 'setup.cmd must be ASCII without BOM.'

    # Test the real launcher without mutating SCM, including environment fallback.
    $savedProgramFiles = $env:ProgramFiles
    $savedProgramW6432 = $env:ProgramW6432
    try {
        $env:ProgramW6432 = ''
        $env:ProgramFiles = $launcher
        $output = & $env:ComSpec /d /c "`"$copy`" status" | Out-String
        Check ($LASTEXITCODE -eq 0 -and $output.Contains((Join-Path $launcher 'MouseWakeSuppressor'))) 'ProgramFiles fallback or space path launcher failed.'
    } finally {
        $env:ProgramFiles = $savedProgramFiles
        $env:ProgramW6432 = $savedProgramW6432
    }

    # Verify production numeric parsing with localized field names.
    function Invoke-Sc { return [pscustomobject]@{Code=0; Text="TYPE : 10 WIN32_OWN_PROCESS`nLOCALIZED : 4 RUNNING"} }
    Check ((Get-ServiceState) -eq 4) 'Numeric SCM parsing failed.'
    function Get-ItemProperty { return @{ ImagePath = '"C:\space path\MouseWakeSuppressorService.exe" --ignored' } }
    Check ((& $productionPath) -eq 'C:\space path\MouseWakeSuppressorService.exe') 'Quoted executable parsing failed.'

    # ACL validation stays inside the disposable fixture.
    $aclDir = Join-Path $root 'ACL fixture'
    New-Item -ItemType Directory -Path $aclDir | Out-Null
    $ini = Join-Path $aclDir 'mws_config.ini'
    $exe = Join-Path $aclDir 'service.exe'
    [IO.File]::WriteAllText($ini, '')
    [IO.File]::WriteAllText($exe, '')
    $beforeDirectory = (Get-Acl -LiteralPath $aclDir).Sddl
    $beforeExe = (Get-Acl -LiteralPath $exe).Sddl
    ${function:Invoke-Native} = $productionNative
    & $productionAcl $ini
    Check ((Get-Acl -LiteralPath $aclDir).Sddl -eq $beforeDirectory) 'Directory ACL changed.'
    Check ((Get-Acl -LiteralPath $exe).Sddl -eq $beforeExe) 'Executable ACL changed.'
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $rule = (Get-Acl -LiteralPath $ini).GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference -eq $users }
    $rw = [Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write
    Check (($rule.FileSystemRights -band $rw) -eq $rw) 'Users do not have INI read/write.'
    # A protected fixture models Program Files without changing system ACLs.
    if ($env:MWS_AHK) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Run INI save validation as a non-administrator user.'
        }
        $acl = Get-Acl -LiteralPath $aclDir
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($entry in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($entry) }
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
            $entry = New-Object Security.AccessControl.FileSystemAccessRule(
                (New-Object Security.Principal.SecurityIdentifier($sid)), $rights,
                'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($entry)
        }
        Set-Acl -LiteralPath $aclDir -AclObject $acl
        & $productionAcl $ini
        & $env:MWS_AHK /ErrorStdOut=UTF-8 (Join-Path $PSScriptRoot 'Tests.Ini.ahk') $aclDir | Out-Host
        Check ($LASTEXITCODE -eq 0) 'Non-administrator AHK INI save or write restriction failed.'
    }
    Write-Host "PASS setup: $checks checks"
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.ToString() + "`n" + $_.ScriptStackTrace)
    exit 1
}
