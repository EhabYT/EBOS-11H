#Requires -Version 5.1
# Removes Windhawk, if installed by install-windhawk.ps1 or by hand.
# Looks for the NSIS uninstaller in the usual install folders and runs it silently (/S).
# If none is found, Windhawk can be removed with Settings > Apps, or:
#   winget uninstall --id RamenSoftware.Windhawk
# Not tested on Windows. Run only if you want Windhawk removed.

$ErrorActionPreference = 'Stop'

$LogDir  = Join-Path $env:WINDIR 'EBOS'
$LogFile = Join-Path $LogDir 'windhawk-uninstall.log'

function Write-WhLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

try {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Windhawk\uninstall.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windhawk\uninstall.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Windhawk\uninstall.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if (-not $candidates) {
        Write-WhLog 'No Windhawk uninstaller found in the standard folders. Nothing removed.'
    } else {
        foreach ($uninst in $candidates) {
            $proc = Start-Process -FilePath $uninst -ArgumentList @('/S') -Wait -PassThru -WindowStyle Hidden
            Write-WhLog ('Ran {0}, exit code {1}' -f $uninst, $proc.ExitCode)
        }
    }
} catch {
    Write-WhLog ('Windhawk uninstall failed: {0}' -f $_.Exception.Message)
}

$global:LASTEXITCODE = 0
