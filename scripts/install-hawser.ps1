<#
.SYNOPSIS
  Install a pinned Hawser release on Windows: download the zip for this
  architecture, verify it against the release's SHA256SUMS, put hawser.exe on
  PATH, and (optionally) install + start the engine and wait until it answers.

.DESCRIPTION
  One script, two callers: the setup-hawser GitHub Action, and GitLab or any
  other CI via before_script. Nothing is fetched as "latest" unless you ask for
  it: -Version pins the Hawser release, and a hawser.lock (auto-detected in the
  working directory, or -Lockfile) pins the engine it installs -- so a laptop
  and a runner converge on the same engine.

  Feature detection keeps it working with older releases: `--locked` and
  `hawser healthcheck` are used only when the installed hawser supports them.

  WSL2 is required to install the engine (GitHub-hosted windows-latest runners
  have it). On a machine without WSL2, run with -Install:$false to stage
  hawser.exe only.

.EXAMPLE
  pwsh -File install-hawser.ps1 -Version 0.3.0
.EXAMPLE
  pwsh -File install-hawser.ps1 -Install:$false          # stage hawser.exe only
#>
[CmdletBinding()]
param(
  [string]$Version = 'latest',
  [string]$Lockfile = '',
  [bool]$Install = $true,
  [string]$InstallArgs = '',
  [string]$Wait = '3m',
  [string]$Dest = '',
  [string]$Token = $env:GH_TOKEN
)
$ErrorActionPreference = 'Stop'
# pwsh 7.4+ turns a native command's non-zero exit into a terminating error under
# ErrorActionPreference=Stop. This script inspects exit codes itself (`hawser
# version` legitimately exits 3 with no engine; `wsl --status` fails where WSL2
# is absent), so keep native exit codes as data, not exceptions.
$PSNativeCommandUseErrorActionPreference = $false
$repo = 'zcsizmadia/hawser'

# Out-CI appends a line to a GitHub Actions command file when running there;
# elsewhere (GitLab, a laptop) the variables are simply unset and nothing happens.
function Out-CI([string]$file, [string]$line) {
  if ($file) { Add-Content -Path $file -Value $line }
}

# --- 1. resolve the release --------------------------------------------------
$Version = $Version -replace '^v', ''
if (-not $Version -or $Version -eq 'latest') {
  # The hawser repo also publishes rootfs releases (tags rootfs-*), and
  # GitHub's /releases/latest can return one of those. "Latest" here means the
  # newest published app release: a v<semver> tag that is not a draft. Every
  # pre-1.0 release is flagged prerelease, so a stable one is preferred when it
  # exists but a prerelease is not excluded.
  $headers = @{ 'User-Agent' = 'setup-hawser' }
  if ($Token) { $headers['Authorization'] = "Bearer $Token" }
  $rels = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/$repo/releases?per_page=50"
  $apps = @($rels | Where-Object { $_.tag_name -match '^v\d+\.\d+\.\d+$' -and -not $_.draft } |
    Sort-Object { [version]($_.tag_name -replace '^v', '') } -Descending)
  $app = @($apps | Where-Object { -not $_.prerelease })[0]
  if (-not $app) { $app = $apps[0] }
  if (-not $app) { throw "no published hawser release found in $repo" }
  $Version = $app.tag_name -replace '^v', ''
}
Write-Host "hawser $Version"

# --- 2. download and verify --------------------------------------------------
$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
$zip = "hawser_${Version}_windows_$arch.zip"
$base = "https://github.com/$repo/releases/download/v$Version"
if (-not $Dest) {
  $tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
  $Dest = Join-Path $tmp "hawser-$Version"
}
New-Item -ItemType Directory -Force $Dest | Out-Null
$zipPath = Join-Path $Dest $zip
$sumsPath = Join-Path $Dest 'SHA256SUMS'
Invoke-WebRequest "$base/$zip" -OutFile $zipPath
Invoke-WebRequest "$base/SHA256SUMS" -OutFile $sumsPath

# SHA256SUMS is `<hash>  <file>` per line; the leading * of binary mode is allowed.
$entry = Get-Content $sumsPath | Where-Object { $_ -match "\s+\*?$([regex]::Escape($zip))\s*$" } | Select-Object -First 1
if (-not $entry) { throw "SHA256SUMS has no entry for $zip" }
$expected = ($entry -split '\s+')[0].ToLower()
$actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw "checksum mismatch for ${zip}: expected $expected, got $actual" }
Write-Host "verified $zip (sha256 $actual)"

$bin = Join-Path $Dest 'bin'
Expand-Archive $zipPath -DestinationPath $bin -Force
$hawser = Join-Path $bin 'hawser.exe'
if (-not (Test-Path $hawser)) { throw "hawser.exe not found after extracting $zip" }

# --- 3. expose ---------------------------------------------------------------
$env:Path = "$bin;$env:Path"
Out-CI $env:GITHUB_PATH $bin
Out-CI $env:GITHUB_ENV "HAWSER_HOME=$bin"
Out-CI $env:GITHUB_OUTPUT "version=$Version"
Out-CI $env:GITHUB_OUTPUT "home=$bin"
# `hawser version` exits 3 with no engine installed; that is expected here.
& $hawser version 2>$null | Out-Host
if (-not $Install) {
  Write-Host "hawser $Version staged at $bin (engine install skipped)"
  exit 0
}

# --- 4. WSL2 gate ------------------------------------------------------------
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
  throw ("WSL2 is not available on this machine (`wsl --status` failed). Enable WSL2 on the runner " +
    "(wsl --install --no-distribution, then reboot), or run with -Install:`$false " +
    "(action input install: false) to stage hawser.exe only.")
}

# --- 5. install the engine (feature-detecting what this release supports) ----
$installHelp = (& $hawser install --help 2>&1 | Out-String)
# Not $args: that is an automatic variable, and assigning to it inside a script
# that also splats it is asking for a subtle argument-passing bug.
$installArgs = @('install', '--headless', '--no-autostart')
if (-not $Lockfile -and (Test-Path 'hawser.lock')) { $Lockfile = 'hawser.lock' }
if ($Lockfile) {
  if ($installHelp -match '--locked') { $installArgs += @('--locked', $Lockfile) }
  else { Write-Warning "hawser $Version does not support --locked; ignoring $Lockfile" }
}
if ($InstallArgs) { $installArgs += ($InstallArgs -split ' ' | Where-Object { $_ }) }
& $hawser @installArgs
if ($LASTEXITCODE -ne 0) { throw "hawser install failed (exit $LASTEXITCODE)" }
& $hawser start
if ($LASTEXITCODE -ne 0) { throw "hawser start failed (exit $LASTEXITCODE)" }

# --- 6. wait until docker commands will succeed -------------------------------
$topHelp = (& $hawser --help 2>&1 | Out-String)
if ($topHelp -match 'healthcheck') {
  & $hawser healthcheck --wait $Wait
  if ($LASTEXITCODE -ne 0) { throw "engine not ready after $Wait" }
} else {
  # Older release: poll status --json ourselves.
  $secs = switch -regex ($Wait) {
    '^(\d+)s$' { [int]$Matches[1] }
    '^(\d+)m$' { 60 * [int]$Matches[1] }
    '^(\d+)h$' { 3600 * [int]$Matches[1] }
    default    { 180 }
  }
  $deadline = (Get-Date).AddSeconds($secs)
  do {
    $st = (& $hawser status --json 2>$null | Out-String | ConvertFrom-Json)
    if ($st.supervisor -eq 'running' -and $st.engine -in @('running', 'idle')) { break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if (-not ($st.supervisor -eq 'running' -and $st.engine -in @('running', 'idle'))) { throw "engine not ready after $Wait" }
}

# docker follows the context Hawser wired at install; anything else in the job
# (compose, Testcontainers, Dev Containers) follows docker.
Out-CI $env:GITHUB_ENV 'DOCKER_CONTEXT=hawser'
Write-Host "engine ready; docker context 'hawser' targets it"
& $hawser status --json | Out-Host
