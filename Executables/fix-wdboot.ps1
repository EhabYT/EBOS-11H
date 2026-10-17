# fix-wdboot.ps1
#
# Runs for EVERY user, not only those who tick Defender removal. The people most
# likely to be carrying a broken WdBoot state are the ones re-applying after the
# bad build, and half of them will not tick the box, so gating this on the option
# meant the repair never reached them.
#
# The guard below is what makes that safe. On a machine where Defender is still
# present, system32\drivers\wd\WdBoot.sys is legitimate, its Platform tree exists
# and Start=0 is correct - writing boot-start state there is exactly what bricked
# people. So: if Defender is present, do nothing at all.

function Write-ElamLog {
  param([string[]]$Lines)
  try {
    $dir = Join-Path $env:windir 'EBOS'
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null }
    $Lines | Out-File -FilePath (Join-Path $dir 'defender-elam.txt') -Append -Encoding utf8
  } catch {}
}

function Test-DefenderPresent {
  try {
    $svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend'
    if (Test-Path $svc) { return $true }
  } catch {}
  try {
    if (Test-Path (Join-Path $env:ProgramFiles 'Windows Defender')) { return $true }
  } catch {}
  return $false
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

if (Test-DefenderPresent) {
  Write-ElamLog @((Get-Date -Format s) + ' - standalone WdBoot pass skipped: Defender is still present on this PC, nothing to repair')
  exit 0
}

Write-ElamLog @((Get-Date -Format s) + ' - standalone WdBoot pass starting (Defender is absent)')
Set-WdBootStart
exit 0
