# EBOS personalization guard
#
# Microsoft has acknowledged that Windows updates from 27 August 2026 (KB5120998)
# onward - the servicing branch that Windows 11 26H2 (build 26300) sits on - reset
# mouse-cursor personalization to an oversized white default and drop custom desktop
# wallpapers to solid black. The wallpaper symptom is reported to come back after
# every sign-out or restart, so applying the settings once at install time is not
# enough on 26H2.
#
# This runs at each logon, compares the live settings against what EBOS installed,
# and puts back only what Windows actually threw away. It writes nothing when the
# settings are already correct, so it costs a few milliseconds on a healthy system.

$ErrorActionPreference = 'SilentlyContinue'

$cursorDir = Join-Path $env:windir 'Cursors\EBOS'

# The playbook stores the wallpaper path UNEXPANDED, as %SystemRoot%\...  Keep
# both forms: the literal one is what gets written back (so the value keeps
# working if Windows is not on C:), the expanded one is only for comparing and
# for the file-exists test. Comparing an expanded path against the unexpanded
# registry value never matches, which made this guard rewrite the wallpaper on
# every single logon and bake in a hard-coded C:\Windows.
$wallpaperRef  = '%SystemRoot%\Web\Wallpaper\EBOS\wallpaper.png'
$wallpaper     = [Environment]::ExpandEnvironmentVariables($wallpaperRef)
$logFile   = Join-Path $env:ProgramData 'EBOS\personalization-guard.log'

function Write-GuardLog([string]$m) {
    try {
        $dir = Split-Path $logFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString('s') + '  ' + $m)
    } catch {}
}

if (-not ('EbosSpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class EbosSpi {
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SpiStr(uint uiAction, uint uiParam, string pvParam, uint fWinIni);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    public static extern bool SpiPtr(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
'@ -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- cursors ----
$roles = [ordered]@{
    'Arrow'       = 'ebos-arrow.ani'
    'Help'        = 'ebos-help.ani'
    'AppStarting' = 'ebos-appstarting.ani'
    'Wait'        = 'ebos-wait.ani'
    'Crosshair'   = 'ebos-cross.ani'
    'IBeam'       = 'ebos-ibeam.ani'
    'NWPen'       = 'ebos-pen.ani'
    'No'          = 'ebos-no.ani'
    'SizeNS'      = 'ebos-sizens.ani'
    'SizeWE'      = 'ebos-sizewe.ani'
    'SizeNWSE'    = 'ebos-sizenwse.ani'
    'SizeNESW'    = 'ebos-sizenesw.ani'
    'SizeAll'     = 'ebos-sizeall.ani'
    'UpArrow'     = 'ebos-up.ani'
    'Hand'        = 'ebos-hand.ani'
    'Pin'         = 'ebos-pin.ani'
    'Person'      = 'ebos-person.ani'
}

$ck = 'HKCU:\Control Panel\Cursors'
$cursorFixed = 0

if (Test-Path $cursorDir) {
    if (-not (Test-Path $ck)) { New-Item -Path $ck -Force | Out-Null }
    foreach ($role in $roles.Keys) {
        $file = Join-Path $cursorDir $roles[$role]
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $want = '%SystemRoot%\Cursors\EBOS\' + $roles[$role]
        # read raw so REG_EXPAND_SZ is not expanded before the comparison
        $have = $null
        try {
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors')
            if ($rk) {
                $have = $rk.GetValue($role, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $rk.Close()
            }
        } catch {}
        if ($have -ne $want) {
            Set-ItemProperty -Path $ck -Name $role -Value $want -Type ExpandString -Force
            $cursorFixed++
        }
    }
    # Read the default value through the raw key: Get-ItemProperty exposes it as
    # '(default)' in lower case, so a '(Default)' property lookup silently misses.
    $haveDefault = $null
    try {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors')
        if ($rk) { $haveDefault = $rk.GetValue('', $null); $rk.Close() }
    } catch {}
    if ($haveDefault -ne 'EBOS') {
        Set-ItemProperty -Path $ck -Name '(Default)' -Value 'EBOS' -Type String -Force
        $cursorFixed++
    }
    # Same reasoning as the installer: an inherited CursorBaseSize makes a
    # correct scheme look wrong, and the 26H2 branch resets personalization.
    $haveSize = (Get-ItemProperty -Path $ck -Name 'CursorBaseSize').CursorBaseSize
    if ($haveSize -ne 32) {
        Set-ItemProperty -Path $ck -Name 'CursorBaseSize' -Value 32 -Type DWord -Force
        $cursorFixed++
    }

    if ($cursorFixed -gt 0) {
        # SPI_SETCURSORS = 0x0057, SPIF_SENDCHANGE = 0x02
        [void][EbosSpi]::SpiPtr(0x0057, 0, [IntPtr]::Zero, 0x02)
        Write-GuardLog ("restored $cursorFixed cursor value(s)")
    }
}

# -------------------------------------------------------------- wallpaper ----
$wallFixed = $false

if (Test-Path -LiteralPath $wallpaper) {
    $dk = 'HKCU:\Control Panel\Desktop'
    $have = (Get-ItemProperty -Path $dk -Name 'Wallpaper').Wallpaper
    $haveExp = if ($have) { [Environment]::ExpandEnvironmentVariables($have) } else { '' }
    if ($haveExp -ne $wallpaper) {
        Set-ItemProperty -Path $dk -Name 'Wallpaper' -Value $wallpaperRef -Type String -Force
        $wallFixed = $true
    }
    if ((Get-ItemProperty -Path $dk -Name 'WallpaperStyle').WallpaperStyle -ne '10') {
        Set-ItemProperty -Path $dk -Name 'WallpaperStyle' -Value '10' -Type String -Force
        $wallFixed = $true
    }
    # Deliberately NOT touching Control Panel\Colors\Background: a black desktop
    # colour is a legitimate user choice and the regression is a failure to LOAD
    # personalization, not a colour change. Guessing there would overwrite a
    # preference rather than repair a fault.
    #
    # The reported symptom is the wallpaper reverting after every sign-out, so the
    # image is pushed through SPI on every logon rather than only when the registry
    # looks wrong - the registry can read correct while nothing is on screen.
    # SPI_SETDESKWALLPAPER = 0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE = 0x03
    [void][EbosSpi]::SpiStr(0x0014, 0, $wallpaper, 0x03)
    if ($wallFixed) { Write-GuardLog 'repaired wallpaper registry values' }
}

exit 0
