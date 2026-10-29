<#
AgentKit Runner — peluncur PowerShell (Windows PowerShell 5.1 dan PowerShell 7 di Windows/macOS/Linux).

Pemakaian online (skrip dari repo publik agentkit-run):
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main/run.ps1))) <GROUP> <PROJECT> <COMMAND> [opsi]

  GROUP   : nama konfigurasi config/<GROUP>.txt
  PROJECT : salah satu proyek dalam konfigurasi grup
  COMMAND : init | build | apply | verify | status | help
          (init tanpa PROJECT: <GROUP> init [PROJECT] -> buat folder tiap proyek, git clone sesuai [repo] di projects/<PROJECT>.conf, lalu apply)
  Opsi    : sama dengan run.sh (--root, --target, --agentkit, --local, --base-url, --branch, --dry-run, --overwrite, --note, --force)

Peluncur ini menjalankan run.sh memakai bash dari Git for Windows (Git Bash), WSL, atau bash sistem,
sehingga perilaku build/apply/verify/status identik di semua sistem operasi.
Konfigurasi grup diambil dari repo publik AgentKit-Run; BASE pada konfigurasi menentukan sumber data patch.
#>
param(
  [Parameter(Position = 0)][string]$Group,
  [Parameter(Position = 1)][string]$Project,
  [Parameter(Position = 2)][string]$Command,
  [Parameter(Position = 3, ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
# Skrip (publik) dan data (privat) ada di dua repo berbeda.
$DefaultRunBase = 'https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main'
$RunBase = if ($env:AGENTKIT_RUN_URL) { $env:AGENTKIT_RUN_URL.TrimEnd('/') } else { $DefaultRunBase }
$Base = if ($env:AGENTKIT_BASE_URL) { $env:AGENTKIT_BASE_URL.TrimEnd('/') } else { $null }
if ($null -eq $Rest) { $Rest = @() }

# --base-url di argumen = URL repo data (dipakai untuk memutuskan pencarian token)
for ($i = 0; $i -lt $Rest.Count - 1; $i++) {
  if ($Rest[$i] -eq '--base-url') { $Base = $Rest[$i + 1].TrimEnd('/') }
}

function Get-GroupBase {
  if (-not $Group -or $Group -notmatch '^[A-Za-z0-9_-]+$') { return $null }
  $candidates = @()
  if ($PSCommandPath) { $candidates += (Join-Path (Split-Path $PSCommandPath -Parent) "config/$Group.txt") }
  $candidates += (Join-Path (Get-Location) "agentkit-run/config/$Group.txt")
  $candidates += (Join-Path (Get-Location) "config/$Group.txt")
  foreach ($path in $candidates) {
    if (Test-Path $path) {
      $line = Get-Content -LiteralPath $path | Where-Object { $_ -match '^BASE=' } | Select-Object -First 1
      if ($line) { return $line.Substring(5).TrimEnd('/') }
    }
  }
  try {
    $text = (Invoke-WebRequest -UseBasicParsing -Uri "$RunBase/config/$Group.txt").Content
    $line = $text -split "`n" | Where-Object { $_ -match '^BASE=' } | Select-Object -First 1
    if ($line) { return $line.Substring(5).TrimEnd().TrimEnd('/') }
  } catch { }
  return $null
}

if (-not $Base) { $Base = Get-GroupBase }

function Find-Bash {
  if ($env:AGENTKIT_BASH -and (Test-Path $env:AGENTKIT_BASH)) { return $env:AGENTKIT_BASH }
  $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
  if ($onWindows) {
    $candidates = @()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
      # ...\Git\cmd\git.exe atau ...\Git\mingw64\bin\git.exe -> ...\Git\bin\bash.exe
      $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
      $candidates += (Join-Path $gitRoot 'bin\bash.exe')
      $candidates += (Join-Path (Split-Path $gitRoot -Parent) 'bin\bash.exe')
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $wsl = Get-Command bash -ErrorAction SilentlyContinue   # WSL (C:\Windows\System32\bash.exe)
    if ($wsl) { return $wsl.Source }
    throw 'bash tidak ditemukan. Pasang Git for Windows (menyertakan Git Bash) atau WSL2, atau set $env:AGENTKIT_BASH.'
  }
  $b = Get-Command bash -ErrorAction SilentlyContinue
  if ($b) { return $b.Source }
  throw 'bash tidak ditemukan di PATH.'
}

function Get-AgentKitToken {
  # AGENTKIT_TOKEN / GITHUB_TOKEN / GH_TOKEN, lalu (hanya untuk sumber GitHub) `gh auth token`,
  # lalu kredensial github.com yang tersimpan di git (Git Credential Manager). Tanpa prompt.
  foreach ($v in @($env:AGENTKIT_TOKEN, $env:GITLAB_TOKEN, $env:GITHUB_TOKEN, $env:GH_TOKEN)) { if ($v) { return $v } }
  if ($Base -match '^https://gitlab\.com/') {
    $glab = Get-Command glab -ErrorAction SilentlyContinue
    if ($glab) {
      $t = (& $glab.Source auth token 2>$null)
      if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    }
    $host = 'gitlab.com'
  } elseif ($Base -match '^https://(raw\.githubusercontent\.com|api\.github\.com|github\.com)/') {
    $host = 'github.com'
  } else { return $null }
  $gh = Get-Command gh -ErrorAction SilentlyContinue
  if ($gh) {
    $t = (& $gh.Source auth token --hostname $host 2>$null)
    if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
  }
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    $old = @{ GIT_TERMINAL_PROMPT = $env:GIT_TERMINAL_PROMPT; GCM_INTERACTIVE = $env:GCM_INTERACTIVE; GIT_ASKPASS = $env:GIT_ASKPASS }
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'; $env:GIT_ASKPASS = $null
    try {
      $out = "protocol=https`nhost=$host`n`n" | & $git.Source -c credential.interactive=false credential fill 2>$null
      foreach ($line in @($out)) { if ($line -like 'password=*') { return $line.Substring(9) } }
    } catch { } finally { foreach ($k in $old.Keys) { Set-Item -Path "env:$k" -Value $old[$k] -ErrorAction SilentlyContinue } }
  }
  return $null
}

function Get-AgentKitScript {
  # Dijalankan sebagai berkas (mis. agentkit-run/run.ps1): pakai run.sh di sebelahnya.
  # Mode lokal: cari run.sh di folder agentkit-run. Selain itu: unduh dari repo publik.
  $local = @()
  if ($PSCommandPath) { $local += (Join-Path (Split-Path $PSCommandPath -Parent) 'run.sh') }
  if ($env:AGENTKIT_SOURCE -eq 'local' -or $Rest -contains '--local') {
    if ($env:AGENTKIT_ROOT) { $local += (Join-Path $env:AGENTKIT_ROOT 'agentkit-run/run.sh') }
    $local += (Join-Path (Get-Location) 'agentkit-run/run.sh')
    $local += (Join-Path (Get-Location) '../agentkit-run/run.sh')
    $local += (Join-Path (Get-Location) 'run.sh')
  }
  foreach ($p in $local) { if (Test-Path $p) { return (Resolve-Path $p).Path } }
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agent_kit_" + [guid]::NewGuid().ToString('N') + '.sh')
  # Repo agentkit-run publik: unduh tanpa token (token hanya untuk data di repo privat).
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "$RunBase/run.sh"
  } catch {
    throw "Tidak bisa mengunduh $RunBase/run.sh ($($_.Exception.Message))."
  }
  $content = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
  # Simpan dengan akhir baris LF (bash menolak CRLF).
  [System.IO.File]::WriteAllText($tmp, ($content -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  return $tmp
}

$bash = Find-Bash
$script:AkToken = Get-AgentKitToken
$shPath = Get-AgentKitScript
$downloaded = $shPath.StartsWith([System.IO.Path]::GetTempPath())
$scriptArg = $shPath -replace '\\', '/'
if ($bash -match 'System32\\bash\.exe$') {
  # WSL: ubah path Windows menjadi /mnt/<drive>/...
  $scriptArg = (& $bash -c "wslpath -a '$scriptArg'").Trim()
}

$argsList = @($scriptArg)
if ($Group) { $argsList += $Group }
if ($Project) { $argsList += $Project }
if ($Command) { $argsList += $Command }
$argsList += $Rest

# Teruskan token ke run.sh (juga ke WSL lewat WSLENV) tanpa mencetaknya.
$prevToken = $env:AGENTKIT_TOKEN; $prevWslEnv = $env:WSLENV
if ($script:AkToken) {
  $env:AGENTKIT_TOKEN = $script:AkToken
}
if ($script:AkToken -or $env:CI_JOB_TOKEN) {
  $env:WSLENV = (@($env:WSLENV, 'AGENTKIT_TOKEN/u', 'AGENTKIT_BASE_URL/u', 'CI_JOB_TOKEN/u') | Where-Object { $_ }) -join ':'
}
try {
  & $bash @argsList
  $code = $LASTEXITCODE
} finally {
  $env:AGENTKIT_TOKEN = $prevToken; $env:WSLENV = $prevWslEnv
}
if ($downloaded) { Remove-Item $shPath -ErrorAction SilentlyContinue }
$global:LASTEXITCODE = $code
# Dijalankan sebagai berkas .ps1: teruskan kode keluar. Dijalankan lewat iwr | scriptblock: jangan menutup sesi.
if ($PSCommandPath) { exit $code }
