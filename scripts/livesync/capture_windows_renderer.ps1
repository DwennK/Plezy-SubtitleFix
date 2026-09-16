param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LiveSyncProbeWindow {
  [StructLayout(LayoutKind.Sequential)]
  public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
}
'@
[LiveSyncProbeWindow]::SetProcessDPIAware() | Out-Null
$executablePath = (Resolve-Path $Executable).Path
$outputPath = (Resolve-Path $OutputDirectory).Path
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$startedAt = [DateTime]::UtcNow
$process = Start-Process -FilePath $executablePath -WorkingDirectory (Split-Path $executablePath) -PassThru -RedirectStandardOutput (Join-Path $outputPath 'stdout.log') -RedirectStandardError (Join-Path $outputPath 'stderr.log')
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  do {
    $process.Refresh()
    if ($process.HasExited) { throw 'Renderer process exited before creating its window' }
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Renderer window deadline exceeded' }
    Start-Sleep -Milliseconds 100
  } while ($process.MainWindowHandle -eq [IntPtr]::Zero)
  $window = $process.MainWindowHandle
  $width = [Math]::Min(1440, $screen.Width)
  $height = [Math]::Min(900, $screen.Height)
  if (-not [LiveSyncProbeWindow]::SetWindowPos($window, [IntPtr]::Zero, $screen.Left, $screen.Top, $width, $height, 0x0040)) {
    throw 'Could not size the dedicated renderer window'
  }
  $captures = @()
  foreach ($state in @('baseline', 'positive', 'negative', 'restored',
      'gap-hidden', 'gap-shown-manual', 'gap-restored', 'gap-hidden-again',
      'gap-manual-hidden', 'gap-release-manual-hidden', 'manual-shown',
      'prediction-contradicted', 'prediction-manual-shown', 'prediction-recovered',
      'capture-on', 'capture-off')) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    $ready = Join-Path $outputPath "$state.json"
    while (-not (Test-Path $ready)) {
      $process.Refresh()
      if ($process.HasExited -or (Test-Path (Join-Path $outputPath 'failure.json'))) { throw "Renderer failed at $state" }
      if ([DateTime]::UtcNow -gt $deadline) { throw "Renderer state deadline exceeded: $state" }
      Start-Sleep -Milliseconds 100
    }
    [LiveSyncProbeWindow]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 500
    if ([LiveSyncProbeWindow]::GetForegroundWindow() -ne $window) { throw 'Dedicated renderer is not foreground' }
    $rect = New-Object LiveSyncProbeWindow+Rect
    if (-not [LiveSyncProbeWindow]::GetWindowRect($window, [ref]$rect)) { throw 'Window bounds unavailable' }
    $bitmap = New-Object System.Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $target = Join-Path $outputPath "$state.png"
    try {
      $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
      $bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
    $captures += @{
      state = $state
      width = $rect.Right - $rect.Left
      height = $rect.Bottom - $rect.Top
      sha256 = (Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Set-Content -Path (Join-Path $outputPath "$state.ack") -Value 'captured'
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not (Test-Path (Join-Path $outputPath 'complete.json'))) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'Renderer did not finish the state sequence' }
    Start-Sleep -Milliseconds 100
  }
  @{
    kind = 'native-windows-renderer-synthetic-fixture'
    screenWidth = $screen.Width
    screenHeight = $screen.Height
    captures = $captures
    visualInspectionRequired = $true
    automaticSynchronizationValidated = $false
  } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outputPath 'capture-provenance.json')
} catch {
  $failureReason = $_.Exception.Message
  $process.Refresh()
  $exited = $process.HasExited
  if ($exited) { $process.WaitForExit() }
  $exitCode = if ($exited) { $process.ExitCode } else { $null }
  @{
    passed = $false
    reason = $failureReason
    state = $state
    processExited = $exited
    processExitCode = $exitCode
    elapsedSeconds = ([DateTime]::UtcNow - $startedAt).TotalSeconds
    source = 'dedicated synthetic renderer process'
  } | ConvertTo-Json | Set-Content (Join-Path $outputPath 'driver-failure.json')
  # A native crash may leave neither a Dart exception nor a live window. Keep
  # the OS fault record for this executable on the disposable hosted runner.
  # Missing event-log access is not evidence that no native crash occurred.
  try {
    $namePattern = [Regex]::Escape((Split-Path $executablePath -Leaf))
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName = 'Application'; StartTime = $startedAt; Id = @(1000, 1001)
      } -ErrorAction Stop | Where-Object { $_.Message -match $namePattern } |
      Select-Object -First 10 TimeCreated, Id, ProviderName, Message)
    @{ available = $true; events = $events } | ConvertTo-Json -Depth 5 |
      Set-Content (Join-Path $outputPath 'process-fault-events.json')
  } catch {
    @{ available = $false; events = @() } | ConvertTo-Json |
      Set-Content (Join-Path $outputPath 'process-fault-events.json')
  }
  # Preserve the real window on failure too, so a UI initialization error is
  # distinguishable from a video/clock failure. This runner contains no user data.
  $process.Refresh()
  if (-not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
    $rect = New-Object LiveSyncProbeWindow+Rect
    [LiveSyncProbeWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 200
    if ([LiveSyncProbeWindow]::GetWindowRect($process.MainWindowHandle, [ref]$rect)) {
      $bitmap = New-Object System.Drawing.Bitmap(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $outputPath 'failure-window.png'), [System.Drawing.Imaging.ImageFormat]::Png)
      } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
  }
  throw
} finally {
  $process.Refresh()
  if (-not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(3000)) { $process.Kill() }
  }
}
