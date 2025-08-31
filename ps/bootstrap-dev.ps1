<#  bootstrap-dev.ps1 — Safe, idempotent setup for Windows Server 2022
    - Pre-inventory: Get-Command only (no external calls)
    - Installs only if missing (winget -> choco fallback)
    - Post-inventory: version probes with 5s timeout each
#>

[CmdletBinding()]
param(
  [string]$NodeVersion = "20.15.1",
  [switch]$InventoryOnly
)

# ---------------- Helpers ----------------

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw "Run this in an elevated PowerShell (Run as Administrator)."
  }
}

function Start-Logging {
  $global:LogPath = Join-Path $env:TEMP ("bootstrap-dev-{0}.log" -f (Get-Date -f "yyyyMMdd-HHmmss"))
  Start-Transcript -Path $global:LogPath -Append | Out-Null
}

function Stop-Logging {
  try { Stop-Transcript | Out-Null } catch {}
  Write-Host "`nLog saved: $global:LogPath"
}

function Have-Cmd($name) { try { $null = Get-Command $name -ErrorAction Stop; $true } catch { $false } }
function Have-Winget     { Have-Cmd winget }

function Ensure-Choco {
  if (Have-Cmd choco) { return $true }
  Write-Host "Chocolatey not found. Installing..." -ForegroundColor Yellow
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  return (Have-Cmd choco)
}

# Run a command with a timeout (seconds); returns first line or "installed"
function Timed-Version([string]$exe, [string]$args="--version", [int]$timeout=5) {
  if (-not (Have-Cmd $exe)) { return $null }
  $sb = [scriptblock]::Create("& $exe $args 2>`$null")
  $job = Start-Job -ScriptBlock $sb
  if (Wait-Job $job -Timeout $timeout) {
    $out = (Receive-Job $job) -join "`n"
    Remove-Job $job -Force | Out-Null
    if ([string]::IsNullOrWhiteSpace($out)) { return "installed" }
    return ($out -split "`n")[0]
  } else {
    Stop-Job $job -Force | Out-Null
    Remove-Job $job -Force | Out-Null
    return "installed"
  }
}

function Print-KV($k,$v) {
  $name = "{0,-22}" -f ("$k:")
  if ($null -eq $v -or $v -eq "") { $v = "—" }
  Write-Host "$name $v"
}

# ---------------- Main -------------------

try {
  Assert-Admin
  Start-Logging
  $ProgressPreference = 'SilentlyContinue'
  $ErrorActionPreference = 'Continue'

  Write-Host "=== INVENTORY (pre) ===" -ForegroundColor Cyan
  Print-KV "pwsh present"            (Have-Cmd pwsh)
  Print-KV "git present"             (Have-Cmd git)
  Print-KV "code (VS Code) present"  (Have-Cmd code)
  Print-KV "docker present"          (Have-Cmd docker)
  Print-KV "winget present"          (Have-Cmd winget)
  Print-KV "choco present"           (Have-Cmd choco)
  Print-KV "java present"            (Have-Cmd java)
  Print-KV "mvn present"             (Have-Cmd mvn)
  Print-KV "gradle present"          (Have-Cmd gradle)
  Print-KV "nvm present"             (Have-Cmd nvm)
  Print-KV "node present"            (Have-Cmd node)
  Print-KV "pnpm present"            (Have-Cmd pnpm)
  Print-KV "yarn present"            (Have-Cmd yarn)
  Print-KV "gh present"              (Have-Cmd gh)
  Print-KV "oh-my-posh present"      (Have-Cmd oh-my-posh)
  Write-Host ""

  if ($InventoryOnly) { Write-Host "Inventory only mode; exiting."; return }

  # --- Core tools ---
  if (-not (Have-Cmd git)) {
    if (Have-Winget) { winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install git -y --no-progress }
  } else { Write-Host "✓ Git present" -ForegroundColor Green }

  if (-not (Have-Cmd pwsh)) {
    if (Have-Winget) { winget install --id Microsoft.PowerShell -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install powershell-core -y --no-progress }
  } else { Write-Host "✓ PowerShell 7 present" -ForegroundColor Green }

  if (-not (Have-Cmd oh-my-posh)) {
    if (Have-Winget) { winget install JanDeDobbeleer.OhMyPosh -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install oh-my-posh -y --no-progress }
  } else { Write-Host "✓ oh-my-posh present" -ForegroundColor Green }

  if (Have-Winget) {
    if (-not (Have-Cmd wt)) {
      winget install --id Microsoft.WindowsTerminal -e --silent --accept-package-agreements --accept-source-agreements
    } else { Write-Host "✓ Windows Terminal present" -ForegroundColor Green }
  } else {
    Write-Host "• Skipping Windows Terminal (winget unavailable)." -ForegroundColor Yellow
  }

  # --- Java & build tools ---
  if (-not (Have-Cmd java)) {
    if (Have-Winget) { winget install --id Microsoft.OpenJDK.21 -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install microsoft-openjdk21 -y --no-progress }
    setx JAVA_HOME "C:\Program Files\Microsoft\jdk-21" | Out-Null
    $env:JAVA_HOME = "C:\Program Files\Microsoft\jdk-21"
  } else { Write-Host "✓ Java present" -ForegroundColor Green }

  if (-not (Have-Cmd mvn)) {
    if (Have-Winget) { winget install --id Apache.Maven -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install maven -y --no-progress }
  } else { Write-Host "✓ Maven present" -ForegroundColor Green }

  if (-not (Have-Cmd gradle)) {
    if (Have-Winget) { winget install --id Gradle.Gradle -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install gradle -y --no-progress }
  } else { Write-Host "✓ Gradle present" -ForegroundColor Green }

  # --- Node toolchain ---
  if (-not (Have-Cmd nvm)) {
    if (Have-Winget) { winget install CoreyButler.NVMforWindows -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install nvm -y --no-progress }
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
  }

  if (Have-Cmd nvm) {
    $installed = (nvm list 2>$null | Select-String $NodeVersion)
    if (-not $installed) { nvm install $NodeVersion }
    nvm use $NodeVersion | Out-Null
    if (-not (Have-Cmd pnpm)) { npm i -g pnpm }
    if (-not (Have-Cmd yarn)) { npm i -g yarn }
    if (-not (Have-Cmd ni))   { npm i -g @antfu/ni }
  } else {
    Write-Host "• nvm not available; skipping Node install." -ForegroundColor Yellow
  }

  # --- GitHub CLI & OpenSSL ---
  if (-not (Have-Cmd gh)) {
    if (Have-Winget) { winget install --id GitHub.cli -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install gh -y --no-progress }
  } else { Write-Host "✓ GitHub CLI present" -ForegroundColor Green }

  if (-not (Have-Cmd openssl)) {
    if (Have-Winget) { winget install --id OpenSSL.OpenSSL -e --silent --accept-package-agreements --accept-source-agreements }
    else { Ensure-Choco | Out-Null; choco install openssl -y --no-progress }
  } else { Write-Host "✓ OpenSSL present" -ForegroundColor Green }

  # --- Git defaults (safe) ---
  if (-not (git config --global --get init.defaultBranch)) { git config --global init.defaultBranch main }
  if (-not (git config --global --get pull.rebase))        { git config --global pull.rebase false }

  # --- Hint for WSL2 ---
  if ((Get-Command wsl -ErrorAction SilentlyContinue) -and -not (wsl --status 2>$null | Select-String "Default Distribution")) {
    Write-Host "Tip: enable WSL2 with Ubuntu →  wsl --install -d Ubuntu" -ForegroundColor DarkCyan
  }

  # -------- Post-inventory (timed) -------
  Write-Host "`n=== INVENTORY (post) ===" -ForegroundColor Cyan
  Print-KV "PowerShell (this)" (Timed-Version "pwsh" "-v")
  Print-KV "Git"               (Timed-Version "git" "--version")
  Print-KV "OpenJDK"           (Timed-Version "java" "-version")
  Print-KV "Maven"             (Timed-Version "mvn" "-version")
  Print-KV "Gradle"            (Timed-Version "gradle" "-version")
  Print-KV "Node"              (Timed-Version "node" "-v")
  Print-KV "npm"               (Timed-Version "npm" "-v")
  Print-KV "pnpm"              (Timed-Version "pnpm" "-v")
  Print-KV "yarn"              (Timed-Version "yarn" "-v")
  Print-KV "GitHub CLI"        (Timed-Version "gh" "--version")
  Print-KV "oh-my-posh"        (Timed-Version "oh-my-posh" "--version")
  if (Have-Winget) { Print-KV "Windows Terminal" (Timed-Version "wt" "-v") }

  Write-Host "`nAll done. Re-run anytime; it only installs what’s missing." -ForegroundColor Green
}
catch {
  Write-Error $_
}
finally {
  Stop-Logging
}
