Start-Sleep 5
# WdBoot Start=0 is BOOT START and is deliberate: Azure Attestation's
# WindowsDefenderElamDriverLoaded claim is what Call of Duty checks, and it can
# only be true if this ELAM driver loads at boot. Do not 'fix' this to 4 - that
# silently reverts the CoD attestation fix. The driver file and its service key
# are deliberately preserved by the Defender removal for the same reason.
#
# It is applied by Set-WdBootStart, which now runs AFTER the deletions below
# rather than here. Written up front it was unconditional, and on a machine whose
# Defender had platform-updated it forced a boot-start driver whose signing
# material this script was about to delete - that machine then failed to boot with
#   \WINDOWS\system32\drivers\wd\WdBoot.sys  0xc0000428
# Checking before the deletions would always have passed, so the check has to
# happen once the final on-disk state exists.
function Write-ElamLog {
  param([string[]]$Lines)
  try {
    $dir = Join-Path $env:windir 'EBOS'
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $Lines | Out-File -FilePath (Join-Path $dir 'defender-elam.txt') -Append -Encoding utf8
  } catch {}
}

function Set-WdBootStart {
  foreach ($cs in @('CurrentControlSet','ControlSet001')) {
    $svcRoot = 'HKLM:\SYSTEM\' + $cs + '\Services'
    $key = $svcRoot + '\WdBoot'
    try {
      if (-not (Test-Path $svcRoot)) { continue }

      # R8, R9 and R10 deleted this key outright, so an upgrade from any of them
      # arrives with no ELAM registration at all and the CoD attestation claim can
      # never be true no matter what the driver file on disk looks like. Recreate it.
      #
      # ImagePath is deliberately the IN-BOX driver and never system32\drivers\wd\.
      # A platform update relocates the live driver into wd\ and its signing material
      # lives in the Platform tree that this script deletes; pointing a boot-start
      # driver at that orphan is exactly what produced the 0xc0000428 boot failure.
      # The in-box copy survives a platform update and stays catalog-signed.
      $recreated = $false
      if (-not (Test-Path $key)) {
        $inbox  = Join-Path $env:windir 'System32\drivers\WdBoot.sys'
        $backup = Join-Path $env:windir 'ELAMBKUP\WdBoot.sys'
        if ((-not (Test-Path -LiteralPath $inbox)) -and (Test-Path -LiteralPath $backup)) {
          # Windows keeps its own backup of the ELAM driver here and nothing in the
          # playbook has ever touched that folder, so it is a clean source.
          try { Copy-Item -LiteralPath $backup -Destination $inbox -Force -ErrorAction Stop } catch {}
        }
        if (Test-Path -LiteralPath $inbox) {
          try {
            New-Item -Path $key -Force -ErrorAction Stop | Out-Null
            # Start is written as 4 here on purpose. The verification below is what
            # promotes it to 0, so a throw between these two points leaves a disabled
            # driver rather than an unbootable machine.
            New-ItemProperty -Path $key -Name 'Start'           -Value 4 -PropertyType DWord  -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'Type'            -Value 1 -PropertyType DWord  -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'ErrorControl'    -Value 1 -PropertyType DWord  -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'SupportElamHive' -Value 0 -PropertyType DWord  -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'Group'           -Value 'Early-Launch' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'ImagePath'       -Value 'system32\drivers\WdBoot.sys' -PropertyType ExpandString -Force -ErrorAction SilentlyContinue | Out-Null
            New-ItemProperty -Path $key -Name 'DisplayName'     -Value 'Windows Defender Boot Driver' -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
            $recreated = $true
            Write-ElamLog @((Get-Date -Format s) + ' - WdBoot service key RECREATED in ' + $cs + ' (upgrade from a build that deleted it)')
          } catch {
            Write-ElamLog @((Get-Date -Format s) + ' - WdBoot service key could not be recreated in ' + $cs + ': ' + $_.Exception.Message)
          }
        } else {
          Write-ElamLog @((Get-Date -Format s) + ' - WdBoot service key absent in ' + $cs + ' and no driver to point it at:',
                          '  in-box:  ' + $inbox,
                          '  backup:  ' + $backup)
        }
      }

      if (-not (Test-Path $key)) { continue }

      # Resolve the driver from ImagePath, never a hardcoded path. A platform
      # update moves it from system32\drivers\WdBoot.sys to
      # system32\drivers\wd\WdBoot.sys and rewrites ImagePath to match, so the
      # two states live at different paths on different machines.
      # The in-box rule above applied only when the key had to be recreated. A clean
      # install on a machine whose Defender had platform-updated arrives with the key
      # ALREADY present and ImagePath already pointing at system32\drivers\wd\, so
      # this ran straight to the verify below and boot-started the orphan anyway:
      #   \WINDOWS\system32\drivers\wd\WdBoot.sys  0xc0000428
      # Normalise it here so every path ends up on the in-box driver, whose signing
      # material does not live in the Platform tree this script deletes.
      try {
        $cur = [string](Get-ItemProperty -Path $key -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
        if ($cur -match 'drivers\\wd\\WdBoot\.sys') {
          $inboxPath = Join-Path $env:windir 'System32\drivers\WdBoot.sys'
          $backupPath = Join-Path $env:windir 'ELAMBKUP\WdBoot.sys'
          if ((-not (Test-Path -LiteralPath $inboxPath)) -and (Test-Path -LiteralPath $backupPath)) {
            try { Copy-Item -LiteralPath $backupPath -Destination $inboxPath -Force -ErrorAction Stop } catch {}
          }
          if (Test-Path -LiteralPath $inboxPath) {
            Set-ItemProperty -Path $key -Name 'ImagePath' -Value 'system32\drivers\WdBoot.sys' -Type ExpandString -Force -ErrorAction SilentlyContinue
            Write-ElamLog @((Get-Date -Format s) + ' - WdBoot ImagePath moved off drivers\wd\ to the in-box driver in ' + $cs)
          }
        }
      } catch {}

      $img = (Get-ItemProperty -Path $key -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
      $path = $null
      if ($img) {
        $rel = [string]$img
        $rel = $rel -replace '^\\\?\?\\', ''
        $rel = $rel -replace '^\\SystemRoot\\', ''
        if ($rel -match '^[A-Za-z]:') { $path = $rel } else { $path = Join-Path $env:windir $rel }
      }

      $loadable = $false
      if ($path -and (Test-Path -LiteralPath $path)) {
        try { $loadable = ((Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop).Status -eq 'Valid') } catch { $loadable = $false }
      }

      if ($loadable) {
        Set-ItemProperty -Path $key -Name 'Start' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-ElamLog @((Get-Date -Format s) + ' - WdBoot ENABLED (Start=0) in ' + $cs + ', CoD attestation should pass:',
                        '  recreated: ' + [string]$recreated,
                        '  ImagePath: ' + $(if ($img) { $img } else { '(none)' }),
                        '  resolved:  ' + $(if ($path) { $path } else { '(unresolved)' }))
      } else {
        # Boot start on a driver Windows cannot verify is an unbootable machine.
        # Disabled costs the attestation claim; boot start would cost the PC.
        Set-ItemProperty -Path $key -Name 'Start' -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-ElamLog @((Get-Date -Format s) + ' - WdBoot left DISABLED (Start=4) in ' + $cs + ', CoD attestation will not pass on this PC:',
                        '  recreated: ' + [string]$recreated,
                        '  ImagePath: ' + $(if ($img) { $img } else { '(none)' }),
                        '  resolved:  ' + $(if ($path) { $path } else { '(unresolved)' }),
                        '  exists:    ' + $(if ($path) { [string](Test-Path -LiteralPath $path) } else { 'False' }))
      }
    } catch {}
  }
}

# ORDER MATTERS AND USED TO BE WRONG. The file deletion below used to run BEFORE the
# services were unregistered, so it was trying to delete Defender's files while
# WinDefend, MDCoreSvc and friends were still registered and runnable. Whatever was
# running held the files, the delete failed, and the script blamed "locked files" and
# forced a reboot. Nothing stopped the services first - there was no Stop-Service
# anywhere in this script. Services go first now, then the files.
$script:svcReport = @()
$defenderServices = @('WinDefend','WdFilter','WdNisDrv','WdNisSvc','MsSecFlt','MsSecWfp','MsSecCore',
                      'SecurityHealthService','Sense','wscsvc','MDCoreSvc','SgrmAgent','SgrmBroker',
                      'webthreatdefsvc','webthreatdefusersvc')

foreach ($svc in $defenderServices) {
  $key = "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
  $existed = $false
  $r = reg query $key /ve 2>&1
  if ($LASTEXITCODE -eq 0) { $existed = $true }

  $wasRunning = $false
  try {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
      $wasRunning = $true
      try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
      try { & sc.exe stop $svc 2>&1 | Out-Null } catch {}
    }
  } catch {}

  if ($existed) { reg delete $key /f 2>&1 | Out-Null }

  $stillThere = $false
  $r2 = reg query $key /ve 2>&1
  if ($LASTEXITCODE -eq 0) { $stillThere = $true }

  $script:svcReport += ('    ' + $svc.PadRight(24) +
    ' present=' + [string]$existed +
    ' wasRunning=' + [string]$wasRunning +
    ' keyRemoved=' + [string]($existed -and -not $stillThere))
}

# The processes themselves, in case a service stop left one behind or something
# non-service is holding MpOAV.dll / MpClient.dll.
$script:procReport = @()
foreach ($pname in @('MsMpEng','MpDefenderCoreService','NisSrv','SecurityHealthService','SecurityHealthSystray','MpCmdRun','MpCopyAccelerator')) {
  try {
    $procs = @(Get-Process -Name $pname -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
      foreach ($p in $procs) {
        try { $p.Kill(); $p.WaitForExit(5000) } catch {}
      }
      $left = @(Get-Process -Name $pname -ErrorAction SilentlyContinue).Count
      $script:procReport += ('    ' + $pname.PadRight(24) + ' found=' + [string]$procs.Count + ' stillRunning=' + [string]$left)
    }
  } catch {}
}
Start-Sleep -Milliseconds 750

$script:stillLocked = @()
$script:folderReport = @()
foreach ($d in @(
  (Join-Path $env:ProgramFiles 'Windows Defender'),
  (Join-Path $env:ProgramFiles 'Windows Defender Advanced Threat Protection'),
  (Join-Path ${env:ProgramFiles(x86)} 'Windows Defender'),
  (Join-Path $env:ProgramData 'Microsoft\Windows Defender'),
  (Join-Path $env:ProgramData 'Microsoft\Windows Defender Advanced Threat Protection')
)) {
  if (-not (Test-Path $d)) {
    $script:folderReport += ('  ' + $d)
    $script:folderReport += '      not present, nothing to do'
    continue
  }

  $before = @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue).Count

  & takeown.exe /F $d /R /A /D Y 2>&1 | Out-Null
  & icacls.exe $d /reset /T /C /Q 2>&1 | Out-Null
  & icacls.exe $d /grant Administrators:F /T /C /Q 2>&1 | Out-Null
  & icacls.exe $d /grant '*S-1-5-18:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
  Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $d) {
    Get-ChildItem -Path $d -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        & takeown.exe /F $_.FullName /A 2>&1 | Out-Null
        & icacls.exe $_.FullName /reset /C /Q 2>&1 | Out-Null
        & icacls.exe $_.FullName /grant Administrators:F /C /Q 2>&1 | Out-Null
        if ($_.PSIsContainer) {
          Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        } else {
          Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
      } catch {}
    }
    & cmd.exe /c ('rmdir /s /q "' + $d + '"') 2>&1 | Out-Null
  }

  $script:folderReport += ('  ' + $d)
  $script:folderReport += ('      files before: ' + [string]$before)
  if (Test-Path $d) {
    # Nothing is queued for boot-time deletion. Report it in full instead so the
    # next person does not have to guess what was holding it.
    $leftovers = @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue)
    $dirsLeft  = @(Get-ChildItem -LiteralPath $d -Recurse -Force -Directory -ErrorAction SilentlyContinue)
    $script:folderReport += ('      REMOVED: NO - ' + [string]$leftovers.Count + ' file(s), ' + [string]$dirsLeft.Count + ' folder(s) remain')
    foreach ($f in $leftovers) {
      $sz = 0; $lw = ''
      try { $sz = $f.Length; $lw = $f.LastWriteTime.ToString('s') } catch {}
      $script:folderReport += ('        ' + $f.FullName)
      $script:folderReport += ('            ext=' + $f.Extension + '  bytes=' + [string]$sz + '  modified=' + $lw + '  attrs=' + [string]$f.Attributes)
    }
    $script:stillLocked += $d
  } else {
    $script:folderReport += '      REMOVED: YES'
  }
}

# Full account of what happened, every run, whether it worked or not.
try {
  $dir = Join-Path $env:windir 'EBOS'
  if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
  $rep = @('============================================================',
           (Get-Date -Format s) + ' - Defender removal report',
           '============================================================',
           '  SERVICES (stopped and unregistered BEFORE any file deletion)')
  $rep += $script:svcReport
  if ($script:procReport.Count -gt 0) {
    $rep += '  PROCESSES killed'
    $rep += $script:procReport
  } else {
    $rep += '  PROCESSES: none of the Defender processes were running'
  }
  $rep += '  FOLDERS'
  $rep += $script:folderReport
  if ($script:stillLocked.Count -gt 0) {
    $rep += ('  RESULT: ' + [string]$script:stillLocked.Count + ' folder(s) could NOT be fully removed.')
    $rep += '          Nothing has been queued and no restart is forced. The files above'
    $rep += '          are inert - their services and COM registrations are gone.'
  } else {
    $rep += '  RESULT: every Defender folder removed on this pass, no restart needed.'
  }
  $rep | Out-File -FilePath (Join-Path $dir 'defender-cleanup.txt') -Append -Encoding utf8
} catch {}

# --- EBOS DefenderToggled persistence (Defender is removed, keys now writable) ---
# Write the four values AME's DefenderToggled requirement reads so later playbook
# upgrades pass without a Security Center that no longer exists.
$dtSets = @(
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection','DisableRealtimeMonitoring',1),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\SpyNet','SpyNetReporting',0),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\SpyNet','SubmitSamplesConsent',0),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\Features','TamperProtection',4)
)
foreach ($e in $dtSets) { try { if (-not (Test-Path $e[0])) { New-Item -Path $e[0] -Force | Out-Null }; Set-ItemProperty -Path $e[0] -Name $e[1] -Value $e[2] -Type DWord -Force -ErrorAction SilentlyContinue } catch {} }
# Recurring re-assert (covers Windows Update wiping the values on later boots)
$keep = Join-Path $env:windir 'EBOS\defender-keep-disabled.ps1'
$keepBody = @'
$ErrorActionPreference = 'SilentlyContinue'
$s = @(
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\Real-Time Protection','DisableRealtimeMonitoring',1),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\SpyNet','SpyNetReporting',0),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\SpyNet','SubmitSamplesConsent',0),
  @('HKLM:\SOFTWARE\Microsoft\Windows Defender\Features','TamperProtection',4)
)
foreach ($e in $s) { try { if (-not (Test-Path $e[0])) { New-Item -Path $e[0] -Force | Out-Null }; Set-ItemProperty -Path $e[0] -Name $e[1] -Value $e[2] -Type DWord -Force } catch {} }
'@
try { Set-Content -Path $keep -Value $keepBody -Encoding UTF8 -Force } catch {}
try {
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoP -EP Bypass -WindowStyle Hidden -File "' + $keep + '"')
  $trg1 = New-ScheduledTaskTrigger -AtLogOn
  $trg2 = New-ScheduledTaskTrigger -Daily -At '03:00'
  Register-ScheduledTask -TaskName 'EBOSDefenderKeepDisabled' -Action $act -Trigger @($trg1,$trg2) -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest) -Force -ErrorAction SilentlyContinue | Out-Null
} catch {}
# Only tear down when everything is actually gone.
# Nothing is queued or rebooted for any more; a locked folder is simply left.
# Runs here, not at the top: every file and key deletion above has happened, so
# this sees the state the machine will actually boot into. Placed before the
# folders-gone branch so it applies on both the reboot path and the teardown path.
# WdBoot lives in fix-wdboot.ps1 so there is one implementation, not two. That script
# also runs ungated in phase 5, but phase 5 happens BEFORE this task removes Defender,
# so its own guard sees Defender still present and correctly skips. This is the call
# that matters on a fresh removal: by here the folders and service keys are gone, so
# the guard passes and it sees the final on-disk state.
try {
  $fixer = Join-Path (Join-Path $env:windir 'EBOS\Tools') 'fix-wdboot.ps1'
  if (Test-Path -LiteralPath $fixer) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixer 2>&1 | Out-Null
  } else {
    Write-ElamLog @((Get-Date -Format s) + ' - fix-wdboot.ps1 not found at ' + $fixer + '; WdBoot not configured')
  }
} catch {
  Write-ElamLog @((Get-Date -Format s) + ' - fix-wdboot.ps1 failed to run: ' + $_.Exception.Message)
}

$defFolders = @(
  (Join-Path $env:ProgramFiles 'Windows Defender'),
  (Join-Path $env:ProgramData  'Microsoft\Windows Defender')
)
$foldersGone = $true
foreach ($d in $defFolders) { if (Test-Path $d) { $foldersGone = $false } }

# No forced restart and nothing scheduled for boot-time deletion. A file that is
# locked is left where it is and recorded in defender-cleanup.txt.
#
# Nothing is lost by leaving it: the AMSI/COM registrations and all fifteen Defender
# service keys are already gone by this point, so the leftovers are inert bytes that
# nothing loads. The restart only ever made the disk tidier, and it is what put
# people into recovery.
if (-not $foldersGone) {
  # A file still here is locked by a process running on THIS boot (MpOAV.dll, the AMSI
  # COM provider, is the usual one). It is inert - service and COM registration are
  # already gone - and the defender-restart-notice forces one more restart. After that
  # restart nothing has it mapped, this task runs once more, deletes it, and the
  # folders are then empty so the teardown below fires. On a not-yet-clean pass there
  # is nothing else to do: log what remains and exit, and try again next logon.
  $remaining = 0
  foreach ($d in $defFolders) {
    if (Test-Path $d) {
      $remaining += @(Get-ChildItem -LiteralPath $d -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    }
  }
  try {
    $dir = Join-Path $env:windir 'EBOS'
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    (@((Get-Date -Format s) + ' - ' + [string]$remaining + ' file(s) left, locked; no reboot forced, nothing queued')) |
      Out-File -FilePath (Join-Path $dir 'defender-cleanup.txt') -Append -Encoding utf8
  } catch {}
  exit 0
}

# Teardown. Folders are empty, so there is nothing left to do: remove the task so it
# stops running at every logon, and clean up its own leftover files.
try { Unregister-ScheduledTask -TaskName 'EBOSDefenderCleanup' -Confirm:$false -ErrorAction SilentlyContinue } catch {}
$ebosDir = Join-Path $env:windir 'EBOS'
foreach ($f in @('ebos-options.txt','ebos-pkgs-current.txt','defender-cleanup-attempts.txt','defender-restart-done.txt')) {
  $fp = Join-Path $ebosDir $f
  if (Test-Path $fp) { Remove-Item -Path $fp -Force -ErrorAction SilentlyContinue }
}
$toolsDir = Join-Path $ebosDir 'Tools'
foreach ($f in @('nuke-defender-files.ps1','nuke-defender-launcher.vbs','defender-cleanup.ps1','defender-cleanup.log')) {
  $fp = Join-Path $toolsDir $f
  if (Test-Path $fp) { Remove-Item -Path $fp -Force -ErrorAction SilentlyContinue }
}
$winreAgent = Join-Path $env:SystemDrive '$WinREAgent'
if (Test-Path $winreAgent) { Remove-Item -Path $winreAgent -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
