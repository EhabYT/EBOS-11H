$ErrorActionPreference = 'SilentlyContinue'
function Write-CdrLog {
    param([string]$Message)
    [Console]::Out.WriteLine('[CDR] ' + $Message)
}

function Test-CdrBlocked {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne 'Deny') { continue }
            $sid = $null
            try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = $ace.IdentityReference.Value }
            if ($sid -eq 'S-1-1-0' -and (($ace.FileSystemRights.value__ -band 32) -ne 0)) { return $true }
        }
    } catch {}
    return $false
}

$cdrGuardDir = Join-Path $env:windir 'EBOS'
$cdrGuardCmd = Join-Path $cdrGuardDir 'cdr-guard.cmd'
$cdrGuardTask = '\EBOS-ResumeGuard'

function Test-CdrGuarded {
    if (-not (Test-Path $cdrGuardCmd)) { return $false }
    try {
        & schtasks.exe /Query /TN $cdrGuardTask 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Install-CdrGuard {
    try {
        & schtasks.exe /Delete /TN '\Microsoft\Windows\Shell\EBOS-X Resume Guard' /F 2>$null | Out-Null
        if (-not (Test-Path $cdrGuardDir)) { New-Item -Path $cdrGuardDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
        $lines = @(
            '@echo off',
            'for /l %%i in (1,1,10) do (',
            '  taskkill /im CrossDeviceResume.exe /f >nul 2>&1 && exit /b 0',
            '  timeout /t 3 /nobreak >nul',
            ')',
            'exit /b 0'
        )
        Set-Content -LiteralPath $cdrGuardCmd -Value $lines -Encoding ASCII -Force -ErrorAction SilentlyContinue
        & schtasks.exe /Create /SC ONLOGON /DELAY 0000:05 /TN $cdrGuardTask /TR $cdrGuardCmd /RU SYSTEM /RL HIGHEST /F 2>$null | Out-Null
    } catch {}
    if (Test-CdrGuarded) {
        Write-CdrLog 'logon guard installed at \EBOS-ResumeGuard - one kill attempt every 3s, exits on first success, gives up after 30s'
    } else {
        Write-CdrLog 'FAILED to install logon guard'
    }
}

function Write-CdrProbe {
    try {
        $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
        foreach ($p in $all) {
            if ($p.Name -ne 'CrossDeviceResume.exe') { continue }
            $parent = 'unknown'
            foreach ($q in $all) { if ($q.ProcessId -eq $p.ParentProcessId) { $parent = $q.Name } }
            Write-CdrLog ('PROBE process pid=' + $p.ProcessId + ' parent=' + $parent + '(' + $p.ParentProcessId + ') cmdline=' + $p.CommandLine)
        }
    } catch {}
    try {
        Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Resume|CrossDevice|Client.CBS' } | ForEach-Object {
            Write-CdrLog ('PROBE package ' + $_.PackageFullName + ' family=' + $_.PackageFamilyName)
        }
    } catch {}
    try {
        Get-ChildItem -Path 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } | ForEach-Object {
            $base = 'Registry::HKEY_USERS\' + $_.PSChildName + '\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
            if (-not (Test-Path $base)) { return }
            Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'Resume|CrossDevice|Client.CBS' } | ForEach-Object {
                $fam = $_.PSChildName
                Get-ChildItem -Path $_.PSPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                    $st = (Get-ItemProperty -Path $_.PSPath -Name 'State' -ErrorAction SilentlyContinue).State
                    if ($null -ne $st) { Write-CdrLog ('PROBE startuptask ' + $fam + ' key=' + $_.PSChildName + ' State=' + $st) }
                }
            }
        }
    } catch {}
}

function Write-CdrState {
    param([string]$Stage)
    $pkgs = @()
    try { $pkgs = @(Get-AppxPackage -AllUsers '*CrossDevice*' | ForEach-Object { $_.PackageFullName }) } catch {}
    $prov = @()
    try { $prov = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like '*CrossDevice*' -or $_.DisplayName -like '*CrossDevice*' } | ForEach-Object { $_.PackageName }) } catch {}
    $dirs = @()
    foreach ($root in @((Join-Path $env:ProgramFiles 'WindowsApps'), (Join-Path $env:windir 'SystemApps'))) {
        if (Test-Path $root) {
            try { $dirs += @(Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*CrossDevice*' } | ForEach-Object { $_.FullName }) } catch {}
        }
    }
    $bins = @()
    foreach ($root in @((Join-Path $env:ProgramFiles 'WindowsApps'), (Join-Path $env:windir 'SystemApps'), (Join-Path $env:windir 'System32'))) {
        if (Test-Path $root) {
            try { $bins += @(Get-ChildItem -Path $root -Recurse -File -Force -Filter 'CrossDeviceResume.exe' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } catch {}
        }
    }
    $tasks = @()
    try { $tasks = @(& schtasks.exe /Query /FO CSV 2>$null | ConvertFrom-Csv | Where-Object { $_.TaskName -match 'CrossDeviceResume' } | ForEach-Object { $_.TaskName }) } catch {}
    $procs = @()
    try { $procs = @(Get-Process -Name 'CrossDeviceResume','CrossDeviceService' -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName }) } catch {}

    $activeBins = @()
    $blockedBins = @()
    foreach ($b in $bins) {
        if (Test-CdrGuarded) { $blockedBins += $b } else { $activeBins += $b }
    }

    Write-CdrLog ($Stage + ' state: packages=' + $pkgs.Count + ' provisioned=' + $prov.Count + ' dirs=' + $dirs.Count + ' binaries=' + $bins.Count + ' (active=' + $activeBins.Count + ' blocked=' + $blockedBins.Count + ') tasks=' + $tasks.Count + ' processes=' + $procs.Count)
    foreach ($x in $pkgs)        { Write-CdrLog ($Stage + ' package   ' + $x) }
    foreach ($x in $prov)        { Write-CdrLog ($Stage + ' provision ' + $x) }
    foreach ($x in $dirs)        { Write-CdrLog ($Stage + ' dir       ' + $x) }
    foreach ($x in $activeBins)  { Write-CdrLog ($Stage + ' binary ACTIVE  ' + $x) }
    foreach ($x in $blockedBins) { Write-CdrLog ($Stage + ' binary guarded ' + $x) }
    foreach ($x in $tasks)       { Write-CdrLog ($Stage + ' task      ' + $x) }
    foreach ($x in $procs)       { Write-CdrLog ($Stage + ' process   ' + $x) }

    $total = $pkgs.Count + $prov.Count + $dirs.Count + $activeBins.Count + $tasks.Count + $procs.Count
    return $total
}

Write-CdrLog ('=== purge starting ===')
$cdrBefore = Write-CdrState -Stage 'BEFORE'
Write-CdrProbe

try { Import-Module Dism -ErrorAction SilentlyContinue } catch {}

try { Unregister-ScheduledTask -TaskName 'EBOS-CrossDeviceClean' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
try { Unregister-ScheduledTask -TaskName 'EBOSCrossDeviceResumeKill' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
$staleClean = Join-Path $env:windir 'EBOS\Tools\crossdevice-clean.ps1'
if (Test-Path $staleClean) { Remove-Item -Path $staleClean -Force }

$pfn = 'MicrosoftWindows.CrossDevice_cw5n1h2txyewy'
$winApps = Join-Path $env:ProgramFiles 'WindowsApps'

Get-Process -Name 'CrossDeviceResume' | Stop-Process -Force
Get-Process -Name 'CrossDeviceService' | Stop-Process -Force

if (Get-Command Set-NonRemovableAppsPolicy -ErrorAction SilentlyContinue) {
    try { Set-NonRemovableAppsPolicy -Online -PackageFamilyName $pfn -NonRemovable 0 -ErrorAction SilentlyContinue | Out-Null } catch {}
}

Get-AppxPackage -AllUsers 'MicrosoftWindows.CrossDevice*' | ForEach-Object { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue } catch {} }
Get-AppxPackage 'MicrosoftWindows.CrossDevice*' | Remove-AppxPackage
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName }

$deprov = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.CrossDevice_cw5n1h2txyewy'
if (-not (Test-Path $deprov)) { New-Item -Path $deprov -Force | Out-Null }
$storeRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
foreach ($leaf in @('Applications','InboxApplications')) {
    $base = Join-Path $storeRoot $leaf
    if (Test-Path $base) {
        Get-ChildItem -Path $base | Where-Object { $_.PSChildName -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force }
    }
}
$eol = Join-Path $storeRoot 'EndOfLife'
if (Test-Path $eol) {
    Get-ChildItem -Path $eol | ForEach-Object {
        Get-ChildItem -Path $_.PSPath | Where-Object { $_.PSChildName -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force }
    }
}
if (Test-Path $winApps) {
    Get-ChildItem -Path $winApps -Directory -Force | Where-Object { $_.Name -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object {
        $p = $_.FullName
        & takeown.exe /F $p /R /D Y 2>$null | Out-Null
        & icacls.exe $p /grant 'administrators:F' /T /C 2>$null | Out-Null
        Remove-Item -Path $p -Recurse -Force
    }
}
$sysApps = Join-Path $env:windir 'SystemApps'
if (Test-Path $sysApps) {
    Get-ChildItem -Path $sysApps -Directory -Force | Where-Object { $_.Name -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object {
        $p = $_.FullName
        & takeown.exe /F $p /R /D Y 2>$null | Out-Null
        & icacls.exe $p /grant 'administrators:F' /T /C 2>$null | Out-Null
        Remove-Item -Path $p -Recurse -Force
    }
}
$cdrBinRoots = @((Join-Path $env:windir 'SystemApps'), (Join-Path $env:ProgramFiles 'WindowsApps'))
foreach ($cdrRoot in $cdrBinRoots) {
    if (-not (Test-Path $cdrRoot)) { continue }
    Get-ChildItem -Path $cdrRoot -Recurse -File -Force -Filter 'CrossDeviceResume.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        $f = $_.FullName
        if (Test-CdrBlocked -Path $f) {
            try {
                & takeown.exe /F $f 2>$null | Out-Null
                & icacls.exe $f /grant 'administrators:F' /C 2>$null | Out-Null
                & icacls.exe $f /remove:d '*S-1-1-0' /C 2>$null | Out-Null
            } catch {}
            if (Test-CdrBlocked -Path $f) {
                Write-CdrLog ('WARNING deny ACE still present on ' + $f + ' - expect a logon popup')
            } else {
                Write-CdrLog ('restored access on ' + $f + ' - file left intact, guard task handles it')
            }
        }
    }
}

$appRepo = Join-Path $env:ProgramData 'Microsoft\Windows\AppRepository'
if (Test-Path $appRepo) {
    Get-ChildItem -Path $appRepo -Force | Where-Object { $_.Name -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object {
        $p = $_.FullName
        & takeown.exe /F $p /R /D Y 2>$null | Out-Null
        & icacls.exe $p /grant 'administrators:F' /T /C 2>$null | Out-Null
        Remove-Item -Path $p -Recurse -Force
    }
    $pkgRepo = Join-Path $appRepo 'Packages'
    if (Test-Path $pkgRepo) {
        Get-ChildItem -Path $pkgRepo -Directory -Force | Where-Object { $_.Name -like 'MicrosoftWindows.CrossDevice*' } | ForEach-Object {
            $p = $_.FullName
            & takeown.exe /F $p /R /D Y 2>$null | Out-Null
            & icacls.exe $p /grant 'administrators:F' /T /C 2>$null | Out-Null
            Remove-Item -Path $p -Recurse -Force
        }
    }
}
$csv = & schtasks.exe /Query /FO CSV 2>$null | ConvertFrom-Csv
foreach ($t in $csv) {
    $n = $t.TaskName
    if ($n -and ($n -match 'CrossDeviceResume')) { & schtasks.exe /Delete /TN $n /F 2>$null | Out-Null }
}
foreach ($r in @((Join-Path $env:windir 'System32\Tasks'), (Join-Path $env:windir 'SysWOW64\Tasks'))) {
    if (Test-Path $r) {
        Get-ChildItem -Path $r -Recurse -File -Force | Where-Object { $_.Name -match 'CrossDeviceResume' } | ForEach-Object { Remove-Item -Path $_.FullName -Force }
    }
}

Install-CdrGuard
$cdrRemaining = Write-CdrState -Stage 'AFTER'
if ($cdrRemaining -eq 0) {
    Write-CdrLog 'RESULT: CrossDeviceResume neutralised - nothing active remaining (removed, or left intact with the logon guard killing it)'
} else {
    Write-CdrLog ('RESULT: CrossDeviceResume STILL ACTIVE - ' + $cdrRemaining + ' items not removed and not guarded, see AFTER lines above')
}
Write-CdrLog ('Windows build ' + (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuildNumber + '.' + (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR)

exit 0
