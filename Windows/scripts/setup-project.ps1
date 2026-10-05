#Requires -Version 5.1
[CmdletBinding()]
param([string]$Proxy = 'http://127.0.0.1:10808', [switch]$Verify, [switch]$BuildInstaller, [switch]$DesktopSession)
$ErrorActionPreference = 'Stop'
$PreviousLocation = Get-Location
$Names = @('HTTP_PROXY','HTTPS_PROXY','NO_PROXY','npm_config_proxy','npm_config_https_proxy','ELECTRON_GET_USE_PROXY','GLOBAL_AGENT_HTTP_PROXY','CI')
$PreviousEnvironment = @{}
foreach ($Name in $Names) { $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name,'Process') }
function Run-Pnpm([string[]]$Arguments) {
    & pnpm.cmd @Arguments
    if ($LASTEXITCODE -ne 0) { throw "pnpm $($Arguments -join ' ') failed with exit $LASTEXITCODE" }
}
try {
    Set-Location (Split-Path $PSScriptRoot -Parent)
    if ($Proxy) {
        $env:HTTP_PROXY = $Proxy
        $env:HTTPS_PROXY = $Proxy
        $env:NO_PROXY = 'localhost,127.0.0.1,::1'
        $env:npm_config_proxy = $Proxy
        $env:npm_config_https_proxy = $Proxy
        $env:ELECTRON_GET_USE_PROXY = '1'
        $env:GLOBAL_AGENT_HTTP_PROXY = $Proxy
    }
    Run-Pnpm -Arguments @('install','--frozen-lockfile','--reporter','append-only')
    # Electron downloads its platform binary lazily. Populate it now while the
    # download proxy is configured, rather than on the first application launch.
    & node.exe node_modules/electron/install.js
    if ($LASTEXITCODE -ne 0) { throw 'Electron Windows runtime installation failed.' }
    if ($Verify -or $BuildInstaller) {
        $env:CI = '1'
        Run-Pnpm -Arguments @('test')
        Run-Pnpm -Arguments @('build')
        Run-Pnpm -Arguments @('test:ui')
        if($DesktopSession){ & (Join-Path $PSScriptRoot 'verify-desktop.ps1') }
        else { Run-Pnpm -Arguments @('test:native') }
    }
    if ($BuildInstaller) { Run-Pnpm -Arguments @('exec','electron-builder','--win','--x64','--publish','never') }
} finally {
    Set-Location $PreviousLocation
    foreach ($Name in $Names) { [Environment]::SetEnvironmentVariable($Name,$PreviousEnvironment[$Name],'Process') }
}
