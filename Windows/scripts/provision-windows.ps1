#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$IncludeNativeTools, [string]$Proxy = 'http://127.0.0.1:10808')
$ErrorActionPreference = 'Stop'
$SetupRoot = Join-Path $env:ProgramData 'CastReader\DevelopmentSetup'
New-Item -ItemType Directory -Force -Path $SetupRoot | Out-Null
$StartTime = Get-Date
$Report = [ordered]@{ startedAt = $StartTime.ToString('o'); host = $env:COMPUTERNAME; platform = 'windows'; packages = @(); complete = $false }
Start-Transcript -Path (Join-Path $SetupRoot 'development-tools.log') -Append
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
function Install-Package([string]$Id, [string]$Override = '') {
    Write-Host "Installing/verifying $Id ..." -ForegroundColor Cyan
    $Arguments = @('install','--id',$Id,'--exact','--source','winget','--silent','--disable-interactivity','--accept-package-agreements','--accept-source-agreements')
    if ($Proxy) { $Arguments += @('--proxy',$Proxy) }
    if ($Override) { $Arguments += @('--override',$Override) }
    & winget.exe @Arguments | Out-Host
    $Exit = $LASTEXITCODE
    # APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE means an equal/newer package is installed.
    if ($Exit -notin @(0,-1978335189,3010)) { throw "WinGet failed for $Id (exit $Exit). See development-tools.log." }
    $Report.packages += [ordered]@{ id = $Id; exitCode = $Exit; checkedAt = (Get-Date).ToString('o') }
    Refresh-Path
}
try {
    $OS = Get-CimInstance Win32_OperatingSystem
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'CastReader Windows currently requires a 64-bit OS.' }
    $FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB,1)
    $Report.os = $OS.Caption
    $Report.osBuild = $OS.BuildNumber
    $Report.memoryGB = [math]::Round($OS.TotalVisibleMemorySize / 1MB,1)
    $Report.freeDiskGB = $FreeGB
    $RequiredGB = if ($IncludeNativeTools) { 15 } else { 5 }
    if ($FreeGB -lt $RequiredGB) { throw "Only $FreeGB GB is free on C:. Need at least $RequiredGB GB for this installation stage." }
    Refresh-Path
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'Windows App Installer / WinGet is unavailable. Install the official Microsoft App Installer before retrying.' }
    if ($Proxy) {
        $ProxyUri = [uri]$Proxy
        $Socket = New-Object Net.Sockets.TcpClient
        try { $Socket.Connect($ProxyUri.Host,$ProxyUri.Port) } catch { throw 'The local proxy is not running. Start v2rayN before installing dependencies.' } finally { $Socket.Dispose() }
        $env:HTTP_PROXY = $Proxy
        $env:HTTPS_PROXY = $Proxy
        $env:NO_PROXY = 'localhost,127.0.0.1,::1,192.168.71.66'
        $env:npm_config_proxy = $Proxy
        $env:npm_config_https_proxy = $Proxy
        $env:ELECTRON_GET_USE_PROXY = '1'
        $env:GLOBAL_AGENT_HTTP_PROXY = $Proxy
        & winget.exe settings --enable ProxyCommandLineOptions | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'WinGet proxy support could not be enabled.' }
    }
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { Install-Package 'Git.Git' }
    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { Install-Package 'OpenJS.NodeJS.LTS' }
    elseif ([int]((& node.exe --version).TrimStart('v').Split('.')[0]) -lt 24) { Install-Package 'OpenJS.NodeJS.LTS' }
    Install-Package 'Microsoft.VisualStudioCode'
    Install-Package 'Google.Chrome'
    if ($IncludeNativeTools) {
        if (-not (Get-Command python.exe -ErrorAction SilentlyContinue)) { Install-Package 'Python.Python.3.13' }
        Install-Package 'Microsoft.VisualStudio.2022.BuildTools' '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    }
    $NodeMajor = [int]((& node.exe --version).TrimStart('v').Split('.')[0])
    if ($NodeMajor -lt 24) { throw 'Node.js 24 or later is required.' }
    if (-not (Get-Command pnpm.cmd -ErrorAction SilentlyContinue)) {
        & npm.cmd install --global pnpm@10.25.0
        if ($LASTEXITCODE -ne 0) { throw 'pnpm installation failed.' }
    }
    if (-not (Get-Command codex.cmd -ErrorAction SilentlyContinue)) {
        & npm.cmd install --global @openai/codex
        if ($LASTEXITCODE -ne 0) { throw 'Codex CLI installation failed.' }
    }
    Refresh-Path
    $Report.gitVersion = (& git.exe --version)
    $Report.nodeVersion = (& node.exe --version)
    $Report.npmVersion = (& npm.cmd --version)
    $Report.pnpmVersion = (& pnpm.cmd --version)
    if ([int]($Report.pnpmVersion.Trim().Split('.')[0]) -lt 10) { throw 'pnpm 10 or later is required.' }
    $Report.projectPnpmVersion = '10.25.0'
    $Report.codexVersion = (& codex.cmd --version)
    if ($IncludeNativeTools) {
        $VsWhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path $VsWhere)) { throw 'Visual Studio Installer validation failed.' }
        $VsRoot = (& $VsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
        if (-not $VsRoot -or -not (Test-Path (Join-Path $VsRoot 'VC\Auxiliary\Build\vcvars64.bat'))) { throw 'MSVC validation failed.' }
        $Report.visualStudioPath = $VsRoot
        $SdkRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
        if (-not $SdkRoot -or -not (Test-Path (Join-Path $SdkRoot 'Include'))) { throw 'Windows SDK validation failed.' }
        $Report.windowsSdkPath = $SdkRoot
    }
    $Report.complete = $true
    Write-Host 'Development tools installed. Repository dependencies and Windows application tests are the next stage.' -ForegroundColor Green
} catch {
    $Report.error = $_.Exception.Message
    throw
} finally {
    $Report.finishedAt = (Get-Date).ToString('o')
    $Report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path (Join-Path $SetupRoot 'development-tools-report.json')
    Stop-Transcript
}
