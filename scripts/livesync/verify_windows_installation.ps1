param(
  [Parameter(Mandatory=$true)][string]$ForkInstaller,
  [Parameter(Mandatory=$true)][string]$OfficialInstaller,
  [Parameter(Mandatory=$true)][string]$Bundle,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
  throw 'Installation proof requires a disposable GitHub-hosted Windows runner'
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LiveSyncInstallWindow {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int height, uint flags);
}
'@
[LiveSyncInstallWindow]::SetProcessDPIAware() | Out-Null
$output = (Resolve-Path $OutputDirectory).Path
$forkSetup = (Resolve-Path $ForkInstaller).Path
$officialSetup = (Resolve-Path $OfficialInstaller).Path
$bundlePath = (Resolve-Path $Bundle).Path
$officialHash = (Get-FileHash $officialSetup -Algorithm SHA256).Hash.ToLowerInvariant()
if ($officialHash -ne '6bd848c708f34918160d584cb3baa9cbe5b248bec4aac4b8b55f6fff42000535') {
  throw 'Official installer does not match the pinned 2.20.0 release asset'
}
$trialRoot = Join-Path $env:RUNNER_TEMP ('livesync-installation-' + [Guid]::NewGuid().ToString('N'))
$officialDirectory = Join-Path $trialRoot 'Official'
$forkDirectory = Join-Path $trialRoot 'Fork'
$officialExe = Join-Path $officialDirectory 'plezy.exe'
$forkExe = Join-Path $forkDirectory 'plezy_livesync.exe'
$officialUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{4213385e-f7be-4f2b-95f9-54082a28bb8f}_is1'
$forkUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{79769758-e214-4a32-a8f8-a31e22b3bfb5}_is1'
$officialData = @((Join-Path $env:APPDATA 'com.edde746\Plezy'), (Join-Path $env:LOCALAPPDATA 'com.edde746\Plezy'))
$forkData = @((Join-Path $env:APPDATA 'DwennK\PlezyLiveSync'), (Join-Path $env:LOCALAPPDATA 'DwennK\PlezyLiveSync'))
# Refuse to run over any existing application or data, even on a hosted image.
foreach ($key in @($officialUninstallKey, $forkUninstallKey, 'Software\Plezy', 'Software\PlezyLiveSync', 'Software\com.edde746\Plezy', 'Software\DwennK\PlezyLiveSync')) {
  foreach ($hive in @('HKCU', 'HKLM')) {
    if (Test-Path "${hive}:\$key") { throw "Pre-existing application registry state: $hive/$key" }
  }
}
foreach ($path in @($officialData + $forkData)) {
  if (Test-Path $path) { throw 'Pre-existing application data; refusing the installation trial' }
}
New-Item -ItemType Directory -Path $trialRoot | Out-Null
$report = [ordered]@{
  kind = 'real-windows-installer-coexistence-trial'
  officialRelease = '2.20.0'
  forkInstallerSha256 = (Get-FileHash $forkSetup -Algorithm SHA256).Hash.ToLowerInvariant()
  officialInstallerSha256 = (Get-FileHash $officialSetup -Algorithm SHA256).Hash.ToLowerInvariant()
  passed = $false
  stages = @()
  captures = @()
  audiblePlaybackValidated = $false
  automaticSynchronizationValidated = $false
}
$owned = @()
function Require([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Run-Setup([string]$Executable, [string]$Arguments) {
  $child = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru
  if (-not $child.WaitForExit(180000)) { $child.Kill(); throw 'Installer operation timed out' }
  Require ($child.ExitCode -eq 0) "Installer operation failed with exit $($child.ExitCode)"
}
function Install-App([string]$Installer, [string]$Directory, [string]$Name) {
  $log = Join-Path $output "$Name-install.log"
  Run-Setup $Installer ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /NORUN=1 /SP- /DIR="{0}" /LOG="{1}"' -f $Directory, $log)
}
function Stop-Owned($Process) {
  if ($null -eq $Process) { return }
  $Process.Refresh()
  if (-not $Process.HasExited) {
    $Process.CloseMainWindow() | Out-Null
    if (-not $Process.WaitForExit(15000)) { $Process.Kill(); $Process.WaitForExit(); throw 'Application did not close normally' }
  }
}
function Launch-App([string]$Executable, [string]$Name) {
  $process = Start-Process -FilePath $Executable -WorkingDirectory (Split-Path $Executable) -PassThru -RedirectStandardOutput (Join-Path $output "$Name-stdout.log") -RedirectStandardError (Join-Path $output "$Name-stderr.log")
  $script:owned += $process
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  do {
    $process.Refresh()
    Require (-not $process.HasExited) "$Name exited during startup"
    Require ([DateTime]::UtcNow -lt $deadline) "$Name did not create a window"
    Start-Sleep -Milliseconds 100
  } while ($process.MainWindowHandle -eq [IntPtr]::Zero)
  Start-Sleep -Seconds 5
  $process.Refresh()
  Require (-not $process.HasExited -and $process.Responding) "$Name did not remain responsive"
  return $process
}
function Capture-App($Process, [string]$Name) {
  $Process.Refresh()
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $window = $Process.MainWindowHandle
  Require ([LiveSyncInstallWindow]::SetWindowPos($window, [IntPtr]::Zero, $screen.Left, $screen.Top, [Math]::Min(1440, $screen.Width), [Math]::Min(900, $screen.Height), 0x0040)) 'Could not size installed application'
  [LiveSyncInstallWindow]::SetForegroundWindow($window) | Out-Null
  Start-Sleep -Milliseconds 500
  Require ([LiveSyncInstallWindow]::GetForegroundWindow() -eq $window) 'Installed application is not foreground'
  $rect = New-Object LiveSyncInstallWindow+Rect
  Require ([LiveSyncInstallWindow]::GetWindowRect($window, [ref]$rect)) 'Installed application bounds unavailable'
  $bitmap = New-Object System.Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $path = Join-Path $output "$Name.png"
  try {
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  return @{ name = $Name; width = $rect.Right - $rect.Left; height = $rect.Bottom - $rect.Top; sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Snapshot-Official {
  $snapshot = [ordered]@{}
  foreach ($directory in @($officialDirectory) + $officialData) {
    $files = @()
    if (Test-Path $directory) {
      $files = @(Get-ChildItem $directory -File -Recurse | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = $_.FullName.Substring($directory.Length); sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
      })
    }
    $snapshot[$directory] = $files
  }
  foreach ($key in @($officialUninstallKey, 'Software\Plezy', 'Software\com.edde746\Plezy')) {
    $values = @()
    if (Test-Path "HKCU:\$key") {
      $keys = @((Get-Item "HKCU:\$key")) + @(Get-ChildItem "HKCU:\$key" -Recurse)
      $values = @($keys | Sort-Object Name | ForEach-Object {
        $item = $_
        foreach ($name in @($item.GetValueNames() | Sort-Object)) {
          [ordered]@{ key = $item.Name; name = $name; kind = $item.GetValueKind($name).ToString(); value = $item.GetValue($name) }
        }
      })
    }
    $snapshot[$key] = $values
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($snapshot | ConvertTo-Json -Depth 12 -Compress))
  $hash = [Security.Cryptography.SHA256]::HashData($bytes)
  return [Convert]::ToHexString($hash).ToLowerInvariant()
}
function Uninstall-App([string]$Directory, [string]$Name) {
  $uninstaller = Join-Path $Directory 'unins000.exe'
  Require (Test-Path $uninstaller) "$Name uninstaller is missing"
  Run-Setup $uninstaller ('/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="{0}"' -f (Join-Path $output "$Name-uninstall.log"))
}
try {
  Install-App $officialSetup $officialDirectory 'official'
  Require (Test-Path $officialExe) 'Official installer did not create its executable'
  Require (Test-Path "HKCU:\$officialUninstallKey") 'Official per-user uninstall identity missing'
  $official = Launch-App $officialExe 'official-initial'
  Stop-Owned $official
  Require (Test-Path $officialData[0]) 'Expected official application-support directory was not created'
  $beforeFork = Snapshot-Official
  $report.stages += 'official-installed-and-launched'

  Install-App $forkSetup $forkDirectory 'fork'
  Require (Test-Path $forkExe) 'Fork installer did not create its executable'
  Require (Test-Path "HKCU:\$forkUninstallKey") 'Fork per-user uninstall identity missing'
  foreach ($file in @(Get-ChildItem $bundlePath -File -Recurse)) {
    $relative = $file.FullName.Substring($bundlePath.Length).TrimStart('\')
    $installed = Join-Path $forkDirectory $relative
    Require (Test-Path $installed) 'Installed fork is missing a bundled file'
    Require ((Get-FileHash $file.FullName).Hash -eq (Get-FileHash $installed).Hash) 'Installed fork differs from the validated bundle'
  }
  $fork = Launch-App $forkExe 'fork'
  Require (Test-Path $forkData[0]) 'Expected fork application-support directory was not created'
  Require ((Snapshot-Official) -eq $beforeFork) 'Fork installation or startup modified official state'
  $report.stages += 'fork-installed-launched-and-isolated'

  $official = Launch-App $officialExe 'official-coexistence'
  Require ($official.Id -ne $fork.Id -and $official.MainWindowHandle -ne $fork.MainWindowHandle) 'The applications did not create independent processes and windows'
  $report.captures += Capture-App $official 'official-coexistence'
  $report.captures += Capture-App $fork 'fork-coexistence'
  $report.stages += 'both-applications-alive'
  Stop-Owned $official
  $beforeRemoval = Snapshot-Official
  Stop-Owned $fork
  Require ((Snapshot-Official) -eq $beforeRemoval) 'Fork shutdown modified official state'
  Uninstall-App $forkDirectory 'fork'
  Require (-not (Test-Path $forkExe)) 'Fork executable survived uninstallation'
  Require (-not (Test-Path "HKCU:\$forkUninstallKey")) 'Fork uninstall registry entry survived uninstallation'
  Require ((Snapshot-Official) -eq $beforeRemoval) 'Fork uninstallation changed the official installation or data'
  Require (Test-Path $forkData[0]) 'Uninstallation unexpectedly removed fork user data'
  $report.stages += 'fork-uninstalled-official-preserved'

  $official = Launch-App $officialExe 'official-after-removal'
  $report.captures += Capture-App $official 'official-after-removal'
  Stop-Owned $official
  $report.stages += 'official-relaunched-after-fork-removal'
  $report.officialStatePreservedAfterForkStartup = $true
  $report.officialStatePreservedAfterForkRemoval = $true
  $report.forkUserDataRetained = $true
  $report.visualInspectionRequired = $true
  $report.passed = $true
} catch {
  $report.failure = $_.Exception.Message
  throw
} finally {
  foreach ($process in $owned) {
    try { Stop-Owned $process } catch { $report.cleanupWarning = $_.Exception.Message }
  }
  # Both installations were absent before this trial and exist only under its
  # unique runner-temporary directory. Never uninstall a pre-existing copy.
  foreach ($entry in @(@{directory=$forkDirectory; name='fork-cleanup'}, @{directory=$officialDirectory; name='official-cleanup'})) {
    if (Test-Path (Join-Path $entry.directory 'unins000.exe')) {
      try { Uninstall-App $entry.directory $entry.name } catch { $report.cleanupWarning = $_.Exception.Message }
    }
  }
  if ($report.Contains('cleanupWarning')) { $report.passed = $false }
  $report | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $output 'installation-result.json')
  if ($report.Contains('cleanupWarning')) { throw 'Installation trial cleanup failed; see installation-result.json' }
}
