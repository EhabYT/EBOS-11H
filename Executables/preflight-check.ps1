# EBOS pre-flight check  -  READ-ONLY, changes nothing
#
# Run this on the PC you intend to apply EBOS to, BEFORE starting AME Wizard:
#     powershell -NoProfile -ExecutionPolicy Bypass -File preflight-check.ps1
#
# It compares the live system against what the playbook is going to do. The lists
# below were extracted from this exact build's task files, so the report reflects
# the playbook you are about to run - not a generic checklist.

$ErrorActionPreference = 'SilentlyContinue'
$report = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ebos-preflight.txt'
$out = New-Object System.Collections.ArrayList
function Say($s) { Write-Host $s; [void]$out.Add($s) }

Say "EBOS pre-flight check"
Say ("run: " + (Get-Date).ToString('s'))
Say ("build expected: EBOS [build 20261008.fb75f1]")
Say ""

# ---------------------------------------------------------------- Windows ----
$cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int](Get-ItemProperty -Path $cv -Name CurrentBuildNumber).CurrentBuildNumber
$disp  = (Get-ItemProperty -Path $cv -Name DisplayVersion).DisplayVersion
$prod  = (Get-ItemProperty -Path $cv -Name ProductName).ProductName
$supported = @(19044, 19045, 22631, 26100, 26200, 26300)
Say ("Windows      : {0}  build {1}  ({2})" -f $prod, $build, $disp)
if ($supported -contains $build) { Say "             : build is SUPPORTED" }
else { Say "             : build is NOT in the supported list - EBOS will refuse" }
Say ""

# ------------------------------------------------------- modified distro -----
Say "Signs of an already-modified Windows"
$marks = @()
foreach ($p in @('C:\Atlas','C:\ReviOS','C:\Tiny11','C:\Ghost Spectre','C:\X-Lite')) {
    if (Test-Path -LiteralPath $p) { $marks += ("path  " + $p) }
}
foreach ($k in @('HKLM:\SOFTWARE\AtlasOS','HKLM:\SOFTWARE\Revision','HKLM:\SOFTWARE\ReviOS')) {
    if (Test-Path -LiteralPath $k) { $marks += ("key   " + $k) }
}
$oem = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
foreach ($n in @('Manufacturer','Model','SupportURL')) {
    if ($oem.$n) { $marks += ("oem   {0} = {1}" -f $n, $oem.$n) }
}
if ($prod -notmatch '^Windows 1[01]') { $marks += ("product name is non-stock: " + $prod) }
if ($marks.Count -eq 0) { Say "  none found - looks like stock Windows" }
else { foreach ($m in $marks) { Say ("  " + $m) } }
Say ""

# ----------------------------------------------------------- the overlap -----
$services = @(
    'AppVClient', 'AssignedAccessManagerSvc', 'BTAGService', 'BTHMODEM',
    'BTHPORT', 'BTHUSB', 'BcastDVRUserService', 'BluetoothUserService',
    'BthA4dp', 'BthAvctpSvc', 'BthEnum', 'BthHFEnum',
    'BthLEEnum', 'BthMini', 'CDPUserSvc', 'CompositeBus',
    'CscService', 'DevQueryBroker', 'DiagTrack', 'DialogBlockingService',
    'EFS', 'ErrDev', 'Fax', 'GpuEnergyDrv',
    'HidBth', 'HvHost', 'InventorySvc', 'MapsBroker',
    'MessagingService', 'Microsoft_Bluetooth_AvrcpTransport', 'NetBT', 'PcaSvc',
    'PimIndexMaintenanceSvc', 'PrintDeviceConfigurationService', 'PrintNotify', 'PrintScanBrokerService',
    'RFCOMM', 'RemoteAccess', 'RemoteRegistry', 'RetailDemo',
    'SCardSvr', 'SEMgrSvc', 'ScDeviceEnum', 'SgrmAgent',
    'SgrmBroker', 'SharedAccess', 'Spooler', 'Telemetry',
    'TrkWks', 'UCPD', 'Vid', 'WMPNetworkSvc',
    'WPCMonSvc', 'WSAIFabricSvc', 'Wecsvc', 'WerSvc',
    'WpnService', 'XblAuthManager', 'XblGameSave', 'XboxGipSvc',
    'XboxNetApiSvc', 'bthserv', 'diagnosticshub.standardcollector.service', 'diagsvc',
    'dmwappushservice', 'edgeupdate', 'edgeupdatem', 'fdc',
    'fhsvc', 'flpydisk', 'hvcrash', 'hvservice',
    'hyperkbd', 'hypervideo', 'icssvc', 'lfsvc',
    'lmhosts', 'printworkflowusersvc', 'serenum', 'serial',
    'sermouse', 'sfloppy', 'shpamsvc', 'stisvc',
    'svsvc', 'troubleshootingsvc', 'uhssvc', 'usbprint',
    'vmicguestinterface', 'vmicheartbeat', 'vmickvpexchange', 'vmicrdv',
    'vmicshutdown', 'vmictimesync', 'vmicvmsession', 'vmicvss',
    'wcncsvc', 'webthreatdefsvc', 'webthreatdefusersvc', 'wercplsupport',
    'whesvc', 'wisvc', 'xbgm'
)
$appx     = @(
    '*ACGMediaPlayer*', '*ActiproSoftwareLLC*', '*Asphalt8*', '*AutodeskSketchBook*',
    '*COOKINGFEVER*', '*CaesarsSlots*', '*CyberLinkMediaSuiteEssentials*', '*DisneyMagicKingdoms*',
    '*DrawboardPDF*', '*Duolingo*', '*EclipseManager*', '*Facebook*',
    '*Fitbit*', '*Flipboard*', '*HiddenCity*', '*Instagram*',
    '*LiveWallpaper*', '*MarchofEmpires*', '*NYTCrossword*', '*OneCalendar*',
    '*Pandora*', '*PhototasticCollage*', '*PicsArt*', '*Plex*',
    '*PolarrPhotoEditor*', '*RoyalRevolt*', '*SecHealthUI*', '*Shazam*',
    '*SlingTV*', '*TuneInRadio*', '*Twitter*', '*Viber*',
    '*WinZip*', '*Wunderlist*', '*XING*', '*iHeartRadio*',
    '7EE7776C.LinkedInforWindows*', 'AD2F1837.HPAIExperienceCenter*', 'AD2F1837.HPConnectedMusic*', 'AD2F1837.HPConnectedPhoto*',
    'AD2F1837.HPDesktopSupportUtilities*', 'AD2F1837.HPEasyClean*', 'AD2F1837.HPFileViewer*', 'AD2F1837.HPJumpStarts*',
    'AD2F1837.HPPCHardwareDiagnostics*', 'AD2F1837.HPPowerManager*', 'AD2F1837.HPPrinterControl*', 'AD2F1837.HPPrivacySettings*',
    'AD2F1837.HPQuickDrop*', 'AD2F1837.HPQuickTouch*', 'AD2F1837.HPRegistration*', 'AD2F1837.HPSupportAssistant*',
    'AD2F1837.HPSureShieldAI*', 'AD2F1837.HPSystemInformation*', 'AD2F1837.HPWelcome*', 'AD2F1837.HPWorkWell*',
    'AD2F1837.myHP*', 'AdobeSystemsIncorporated.AdobePhotoshopExpress*', 'Amazon.com.Amazon*', 'AmazonVideo.PrimeVideo*',
    'AppleInc.AppleMusicWin*', 'AppleInc.iTunes*', 'BookingApp*', 'Clipchamp.Clipchamp*',
    'DellInc.DellDigitalDelivery*', 'DellInc.DellMobileConnect*', 'DellInc.DellSupportAssist*', 'Disney.*',
    'E046963F.LenovoCompanion*', 'HULULLC.HULUPLUS*', 'LenovoCompanyLimited.LenovoVantageService*', 'MSCopilot*',
    'MSTeams*', 'Microsoft.549981C3F5F10*', 'Microsoft.Advertising.Xaml*', 'Microsoft.BingNews*',
    'Microsoft.BingSearch*', 'Microsoft.BingWeather*', 'Microsoft.Copilot*', 'Microsoft.Copilot365*',
    'Microsoft.Edge.GameAssist*', 'Microsoft.Flipgrid*', 'Microsoft.GamingApp*', 'Microsoft.GetHelp*',
    'Microsoft.Getstarted*', 'Microsoft.M365Companions*', 'Microsoft.MSPaint*', 'Microsoft.Microsoft3DViewer*',
    'Microsoft.MicrosoftCopilot*', 'Microsoft.MicrosoftJournal*', 'Microsoft.MicrosoftOfficeHub*', 'Microsoft.MicrosoftPowerBIForWindows*',
    'Microsoft.MicrosoftSolitaireCollection*', 'Microsoft.MicrosoftStickyNotes*', 'Microsoft.MicrosoftTeamsforSurfaceHub*', 'Microsoft.MixedReality.Portal*',
    'Microsoft.NetworkSpeedTest*', 'Microsoft.Office.Excel*', 'Microsoft.Office.OneNote*', 'Microsoft.Office.PowerPoint*',
    'Microsoft.Office.Sway*', 'Microsoft.Office.Word*', 'Microsoft.OutlookForWindows*', 'Microsoft.OutlookPWA*',
    'Microsoft.PCManager*', 'Microsoft.People*', 'Microsoft.PowerAutomateDesktop*', 'Microsoft.SkypeApp*',
    'Microsoft.StartExperiencesApp*', 'Microsoft.Todos*', 'Microsoft.Whiteboard*', 'Microsoft.WidgetsPlatformRuntime*',
    'Microsoft.Windows.AIHub*', 'Microsoft.Windows.Ai.Copilot.Provider*', 'Microsoft.Windows.Apprep.ChxApp*', 'Microsoft.Windows.AugLoop.CBS*',
    'Microsoft.Windows.Copilot*', 'Microsoft.Windows.DevHome*', 'Microsoft.Windows.PeopleExperienceHost*', 'Microsoft.Windows.SecureAssessmentBrowser*',
    'Microsoft.WindowsAlarms*', 'Microsoft.WindowsCamera*', 'Microsoft.WindowsFeedbackHub*', 'Microsoft.WindowsMaps*',
    'Microsoft.WindowsSoundRecorder*', 'Microsoft.WindowsStore*', 'Microsoft.Xbox*', 'Microsoft.XboxApp*',
    'Microsoft.XboxGameOverlay*', 'Microsoft.XboxGamingOverlay*', 'Microsoft.XboxIdentityProvider*', 'Microsoft.XboxSpeechToTextOverlay*',
    'Microsoft.ZuneMusic*', 'Microsoft.ZuneVideo*', 'MicrosoftCorporationII.Bing*', 'MicrosoftCorporationII.MailforSurfaceHub*',
    'MicrosoftCorporationII.MicrosoftFamily*', 'MicrosoftCorporationII.QuickAssist*', 'MicrosoftTeams*', 'MicrosoftWindows.Client.AIX*',
    'MicrosoftWindows.Client.Copilot*', 'MicrosoftWindows.UndockedDevKit*', 'king.com.BubbleWitch3Saga*', 'king.com.CandyCrushSaga*',
    'king.com.CandyCrushSodaSaga*', 'king.com.FarmHeroesSaga*', 'microsoft.windowscommunicationsapps*'
)

$svcMissing = 0; $svcDisabled = 0; $svcLive = 0
foreach ($s in $services) {
    $o = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $o) { $svcMissing++; continue }
    $st = (Get-ItemProperty -Path ("HKLM:\SYSTEM\CurrentControlSet\Services\" + $s) -Name Start).Start
    if ($st -eq 4) { $svcDisabled++ } else { $svcLive++ }
}
Say ("Services the playbook disables : {0} total" -f $services.Count)
Say ("  already absent               : {0}" -f $svcMissing)
Say ("  already disabled             : {0}" -f $svcDisabled)
Say ("  still active, EBOS will change: {0}" -f $svcLive)
Say ""

$installed = @(Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name -Unique)
$appxGone = 0; $appxHere = 0
foreach ($a in $appx) {
    $pat = $a.TrimEnd('*')
    if ($installed | Where-Object { $_ -like ($pat + '*') }) { $appxHere++ } else { $appxGone++ }
}
Say ("Appx packages the playbook removes : {0} total" -f $appx.Count)
Say ("  already gone                     : {0}" -f $appxGone)
Say ("  still present                    : {0}" -f $appxHere)
Say ""

# ------------------------------------------------------------- verdict ------
$overlapSvc  = if ($services.Count) { [math]::Round(100.0 * ($svcMissing + $svcDisabled) / $services.Count) } else { 0 }
$overlapAppx = if ($appx.Count)     { [math]::Round(100.0 * $appxGone / $appx.Count) } else { 0 }
Say ("Overlap: {0}% of the services and {1}% of the appx packages EBOS targets" -f $overlapSvc, $overlapAppx)
Say          "         have already been removed or disabled by something else."
Say ""
if ($marks.Count -gt 0 -or $overlapSvc -gt 40 -or $overlapAppx -gt 40) {
    Say "VERDICT: this is NOT a stock Windows installation."
    Say "         EBOS assumes stock Windows. Running it here can leave the system"
    Say "         in a state neither tool expects, and most of it cannot be undone."
    Say "         Take a FULL DISK IMAGE first, or install stock Windows and apply EBOS there."
} else {
    Say "VERDICT: looks like a stock installation - the usual precautions apply."
}
Say ""
Say ("report written to: " + $report)
$out | Set-Content -LiteralPath $report -Encoding UTF8
