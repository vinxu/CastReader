#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$Packaged)
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
$TaskName='CastReader-Verify-' + [guid]::NewGuid().ToString('N')
$Output=Join-Path $Root 'test-results\desktop-check'
New-Item -ItemType Directory -Force $Output | Out-Null
$Runner=Join-Path $Output ($TaskName + '.ps1')
$Log=Join-Path $Output ($TaskName + '.log')
$Node=(Get-Command node.exe).Source.Replace("'","''")
$Smoke=(Join-Path $PSScriptRoot 'smoke-electron.mjs').Replace("'","''")
$Flag=if($Packaged){' --packaged'}else{''}
@("& '$Node' '$Smoke'$Flag *> '$($Log.Replace("'","''"))'",'exit $LASTEXITCODE') | Set-Content -Encoding UTF8 $Runner
$Action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $Runner + '"') -WorkingDirectory $Root
$Principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
$Settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
$Registered=$false
try {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Settings $Settings | Out-Null
    $Registered=$true
    Start-ScheduledTask -TaskName $TaskName
    $Deadline=(Get-Date).AddMinutes(4)
    do {
        Start-Sleep -Seconds 2
        $Task=Get-ScheduledTask -TaskName $TaskName
        $Info=Get-ScheduledTaskInfo -TaskName $TaskName
        if((Get-Date) -ge $Deadline){throw 'Desktop verification timed out. Keep the Windows user signed in.'}
    } while($Task.State -eq 'Running' -or $Info.LastRunTime.Year -lt 2000)
    if(Test-Path $Log){Get-Content $Log | Out-Host}
    if($Info.LastTaskResult -ne 0){throw "Desktop verification failed ($($Info.LastTaskResult)). See $Log"}
} finally {
    if($Registered){
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Remove-Item $Runner -ErrorAction SilentlyContinue
}
