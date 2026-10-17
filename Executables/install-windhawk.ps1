#Requires -Version 5.1
# Silent install of Windhawk 1.7.3 (no mods, no configuration).
# Installer: windhawk_setup.exe from https://github.com/ramensoftware/windhawk/releases/tag/v1.7.3
# SHA-256 of the bundled file is checked before it is run. A mismatch stops the step.
# Silent switches /S /STANDARD are NSIS switches (see the Windhawk install docs and winget manifest).
# Not tested on Windows.

$ErrorActionPreference = 'Stop'

$ExpectedSha256 = '5116CC1703384AAC88B8D7A3B57F172AEA5DA32B6DF7355FB2F8247D23813C8F'
$LogDir  = Join-Path $env:WINDIR 'EBOS'
$LogFile = Join-Path $LogDir 'windhawk-install.log'

function Write-WhLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

try {
    $setup = Join-Path $PSScriptRoot 'windhawk_setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        Write-WhLog 'windhawk_setup.exe not found next to the script. Step skipped.'
        $global:LASTEXITCODE = 0
        return
    }

    $actual = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedSha256) {
        Write-WhLog ('SHA-256 mismatch for windhawk_setup.exe: expected {0}, got {1}. Not run.' -f $ExpectedSha256, $actual)
        $global:LASTEXITCODE = 0
        return
    }

    $proc = Start-Process -FilePath $setup -ArgumentList @('/S', '/STANDARD') -Wait -PassThru -WindowStyle Hidden
    Write-WhLog ('Windhawk installer exit code: {0}' -f $proc.ExitCode)
} catch {
    $msg = $_.Exception.Message
    Write-WhLog ('Windhawk install failed: {0}' -f $msg)
}

$global:LASTEXITCODE = 0
