param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
  throw 'Renderer comparison requires a disposable hosted runner'
}
$executablePath = (Resolve-Path $Executable).Path
$root = (Resolve-Path $OutputDirectory).Path
$active = Join-Path $root 'active'
$reportPath = Join-Path $root 'observer-comparison.json'
if ((Test-Path $active) -or (Test-Path $reportPath)) { throw 'Comparison output must be fresh' }
$driver = Join-Path $PSScriptRoot 'capture_windows_renderer.ps1'
$bundle = Split-Path $executablePath
function Get-BinaryHashes {
  $hashes = [ordered]@{}
  foreach ($name in @('plezy_livesync.exe', 'flutter_windows.dll', 'libmpv-2.dll')) {
    $hashes[$name] = (Get-FileHash (Join-Path $bundle $name) -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  return $hashes
}
$baseline = Get-BinaryHashes
$baselineJson = $baseline | ConvertTo-Json -Compress
function Assert-RendererStopped {
  $remaining = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($executablePath)) -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $executablePath })
  if ($remaining.Count -gt 0) { throw 'Renderer still running; refusing to overlap comparison trials' }
}
$trials = @()
$previousLog = $env:LIVESYNC_RENDERER_EXCEPTION_LOG
try {
  # Fixed balanced order, not retry-until-green. Keep all failures. All launches
  # use the same compiled runner; only observer registration changes. Warm OS
  # caches and persisted window geometry are not reset between trials.
  foreach ($enabled in @($false, $true, $true, $false, $false, $true)) {
    $ordinal = $trials.Count + 1
    $mode = if ($enabled) { 'on' } else { 'off' }
    $destination = Join-Path $root ("trial-{0}-{1}" -f $ordinal, $mode)
    if (Test-Path $destination) { throw 'Trial output already exists' }
    Assert-RendererStopped
    if (((Get-BinaryHashes) | ConvertTo-Json -Compress) -ne $baselineJson) { throw 'Renderer binaries changed between trials' }
    New-Item -ItemType Directory $active | Out-Null
    $faultLog = Join-Path $active 'native-faults.jsonl'
    if ($enabled) { $env:LIVESYNC_RENDERER_EXCEPTION_LOG = $faultLog }
    else { Remove-Item Env:LIVESYNC_RENDERER_EXCEPTION_LOG -ErrorAction SilentlyContinue }
    $startedAt = [DateTime]::UtcNow
    # A fresh driver process avoids reusing loaded Add-Type definitions. Its
    # finally block waits for the exact renderer process to terminate.
    & pwsh -NoProfile -File $driver -Executable $executablePath -OutputDirectory $active
    $driverExit = $LASTEXITCODE
    Assert-RendererStopped
    $observerVerified = -not (Test-Path $faultLog)
    if ($enabled) {
      $observerVerified = $false
      if (Test-Path $faultLog) {
        $first = Get-Content $faultLog -First 1 | ConvertFrom-Json
        $observerVerified = $first.event -eq 'installed' -and $first.debuggerPresent -eq $false
      }
    }
    $passed = $driverExit -eq 0 -and $observerVerified -and (Test-Path (Join-Path $active 'complete.json'))
    $trials += @{
      ordinal = $ordinal; observerEnabled = $enabled; observerStateVerified = $observerVerified
      driverExitCode = $driverExit; passed = $passed
      elapsedSeconds = ([DateTime]::UtcNow - $startedAt).TotalSeconds
      evidenceDirectory = Split-Path $destination -Leaf
    }
    Move-Item $active $destination
  }
} finally {
  if ($null -eq $previousLog) { Remove-Item Env:LIVESYNC_RENDERER_EXCEPTION_LOG -ErrorAction SilentlyContinue }
  else { $env:LIVESYNC_RENDERER_EXCEPTION_LOG = $previousLog }
  @{
    kind = 'same-binary-renderer-observer-comparison'; binaries = $baseline
    expectedTrials = 6; completedTrials = $trials.Count; trials = $trials
    allTrialsPassed = $trials.Count -eq 6 -and @($trials | Where-Object { -not $_.passed }).Count -eq 0
    normalUninstrumentedBinaryValidated = $false; automaticSynchronizationValidated = $false
    limitations = @('Observer code is compiled into both modes; this does not compare binary layout.',
      'Fixed off/on/on/off/off/on order, shared OS caches and persisted window geometry.',
      'Synthetic renderer on a hosted WARP desktop; no physical GPU or audible playback proof.')
  } | ConvertTo-Json -Depth 6 | Set-Content $reportPath
}
if (@($trials | Where-Object { -not $_.passed }).Count -gt 0) { throw 'One or more renderer comparison trials failed; all results retained' }
