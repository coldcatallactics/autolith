param([string]$Image = 'mcr.microsoft.com/windows/servercore:ltsc2025')
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$containers = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
$root = Join-Path $env:RUNNER_TEMP ('autolith-wcow-' + [Guid]::NewGuid().ToString('N'))

function Invoke-NativeChecked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}

function Invoke-Wcow {
    param([string[]]$Options, [string]$Program)
    $name = 'autolith-probe-' + [Guid]::NewGuid().ToString('N')
    $containers.Add($name)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Program))
    $arguments = @('run', '--name', $name, '--isolation=process') + $Options + @(
        $script:imageId, 'powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive',
        '-EncodedCommand', $encoded)
    Invoke-NativeChecked 'docker.exe' $arguments
}

function Test-WcowProbe {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS: $Name"
    } catch {
        $failures.Add($Name)
        Write-Host "FAIL: ${Name}: $_"
    }
}

Invoke-NativeChecked 'whoami.exe' @('/groups')
Invoke-NativeChecked 'docker.exe' @('version')
Invoke-NativeChecked 'docker.exe' @('info')
Invoke-NativeChecked 'docker.exe' @('pull', $Image)
$script:imageId = (& docker.exe image inspect --format '{{.Id}}' $Image).Trim()
if ($LASTEXITCODE -ne 0 -or -not $script:imageId.StartsWith('sha256:')) {
    throw 'Could not resolve the exact container image.'
}
Write-Host "Container image: $Image $script:imageId"
$gitExecutable = (Get-Command git.exe -CommandType Application).Source
$gitRoot = Split-Path (Split-Path $gitExecutable -Parent) -Parent
$workspace = Join-Path $root 'workspace'
$private = Join-Path $root 'private'
$readOnly = Join-Path $root 'read-only'
New-Item -ItemType Directory -Path $workspace, $private, $readOnly | Out-Null
[IO.File]::WriteAllText((Join-Path $readOnly 'marker'), 'host-read-only')
Invoke-NativeChecked 'icacls.exe' @($root, '/grant', '*S-1-5-11:(OI)(CI)M', '/T', '/Q')
$mounts = @('--mount', "type=bind,source=$workspace,target=C:\workspace",
            '--mount', "type=bind,source=$private,target=C:\private",
            '--mount', "type=bind,source=$gitRoot,target=C:\native-git,readonly",
            '--mount', "type=bind,source=$readOnly,target=C:\read-only,readonly")
$listener = $null
try {
    Test-WcowProbe 'unmodified Git, NUL, and worktrees' {
        Invoke-Wcow ($mounts + @('--network=none', '--workdir=C:\workspace')) @'
$ErrorActionPreference = 'Stop'
$env:PATH = 'C:\native-git\cmd;C:\native-git\mingw64\bin;' + $env:PATH
$env:HOME = 'C:\private'
$env:TEMP = 'C:\private'
$env:TMP = 'C:\private'
function Git { & C:\native-git\cmd\git.exe @args; if ($LASTEXITCODE -ne 0) { throw "Git exited $LASTEXITCODE" } }
& cmd.exe /d /c 'type NUL'
if ($LASTEXITCODE -ne 0) { throw 'NUL read failed' }
& cmd.exe /d /c 'echo discarded>NUL'
if ($LASTEXITCODE -ne 0) { throw 'NUL write failed' }
Git --version
Git init
Git config user.name 'Autolith native probe'
Git config user.email 'probe@example.invalid'
[IO.File]::WriteAllText('C:\workspace\tracked.txt', 'native Git')
Git add tracked.txt
Git commit -m 'Create native probe fixture'
Git status --porcelain
Git worktree add -b native-probe C:\workspace\linked
Git -C C:\workspace\linked status --porcelain
Git worktree remove C:\workspace\linked
'@
    }
    foreach ($name in @('.git', '.agents', '.codex')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $workspace $name) | Out-Null
    }
    $protectedMounts = @()
    foreach ($name in @('.git', '.agents', '.codex')) {
        $path = Join-Path $workspace $name
        [IO.File]::WriteAllText((Join-Path $path 'protected-marker'), 'protected')
        $protectedMounts += @('--mount', "type=bind,source=$path,target=C:\workspace\$name,readonly")
    }
    Test-WcowProbe 'nested read-only metadata mounts and workspace writes' {
        Invoke-Wcow ($mounts + $protectedMounts + @('--network=none')) @'
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText('C:\workspace\allowed-write', 'allowed')
foreach ($name in @('.git', '.agents', '.codex')) {
    $path = 'C:\workspace\' + $name + '\protected-marker'
    if ([IO.File]::ReadAllText($path) -ne 'protected') { throw 'Protected mount is not readable' }
    $denied = $false
    try { [IO.File]::WriteAllText($path, 'forbidden') } catch { $denied = $true }
    if (-not $denied) { throw "Protected write succeeded: $path" }
}
$denied = $false
try { [IO.File]::WriteAllText('C:\read-only\marker', 'forbidden') } catch { $denied = $true }
if (-not $denied) { throw 'Host read-only write succeeded' }
'@
    }
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
    $hostAddress = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 |
                    Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
    if (-not $hostAddress) { throw 'No host IPv4 address for controlled network probe.' }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $firewallName = 'Autolith-WCOW-' + [Guid]::NewGuid().ToString('N')
    New-NetFirewallRule -Name $firewallName -DisplayName $firewallName -Direction Inbound `
        -Action Allow -Protocol TCP -LocalPort $port -Profile Any | Out-Null
    $networkEnvironment = @('--env', "PROBE_HOST=$hostAddress", '--env', "PROBE_PORT=$port")
    $networkProgram = @'
$ErrorActionPreference = 'Stop'
$client = [Net.Sockets.TcpClient]::new()
$connected = $false
try {
    $pending = $client.ConnectAsync($env:PROBE_HOST, [int]$env:PROBE_PORT)
    if ($pending.Wait(5000)) { $connected = $client.Connected }
} catch { $connected = $false } finally { $client.Dispose() }
$expected = $env:PROBE_CONNECTED -eq 'yes'
if ($connected -ne $expected) { throw "Expected connected=$expected, observed $connected" }
'@
    $controlPassed = $false
    Test-WcowProbe 'network control reaches the host listener' {
        Invoke-Wcow ($networkEnvironment + @('--env', 'PROBE_CONNECTED=yes')) $networkProgram
        $script:controlPassed = $true
    }
    if ($controlPassed) {
        Test-WcowProbe 'network=none denies the same host listener' {
            Invoke-Wcow ($networkEnvironment + @('--network=none', '--env', 'PROBE_CONNECTED=no')) $networkProgram
        }
    } else {
        $failures.Add('network isolation lacks a working control')
    }
} finally {
    if ($listener) { $listener.Stop() }
    if ($firewallName) { Remove-NetFirewallRule -Name $firewallName }
    foreach ($name in $containers) {
        & docker.exe rm --force $name 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
if ($failures.Count -gt 0) { throw ('Failed probes: ' + ($failures -join ', ')) }
Write-Host 'All WCOW feasibility probes passed. Standard-account runtime access and lifecycle are not established by this probe.'
exit 0
