# Windows launcher for the bitwarden skill (UNTESTED: written without access to a Windows machine).
# Sets up WSL2 + Ubuntu if needed, then runs the normal Linux installer inside it.
#   Double-click install-windows.cmd, or:  powershell -ExecutionPolicy Bypass -File install-windows.ps1 [-Expect FINGERPRINT]
param([string]$Expect = "", [switch]$Resume, [string]$Distro = "Ubuntu")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
$Title = "OpenClaw Bitwarden installer"
$Self  = $MyInvocation.MyCommand.Path
$Skill = Split-Path -Parent (Split-Path -Parent $Self)

function Say($text, $buttons = "OK") {
  [System.Windows.Forms.MessageBox]::Show($text, $Title, $buttons, "Information")
}
function Wsl { param([Parameter(ValueFromRemainingArguments)]$a) & wsl.exe @a; if ($LASTEXITCODE -ne 0) { throw "wsl $($a -join ' ') failed ($LASTEXITCODE)" } }
[Console]::OutputEncoding = [System.Text.Encoding]::Unicode   # wsl.exe prints UTF-16

function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole("Administrator") }
function Distro-Installed { $l = (& wsl.exe -l -q 2>$null) -join "`n"; return ($l -split "`r?`n" | ForEach-Object { $_.Trim([char]0, ' ') }) -contains $Distro }

# 1. Explain, then elevate (UAC) once.
if (-not $Resume -and -not (Test-Admin)) {
  $r = Say "OpenClaw wants to install a safer Bitwarden helper. On Windows it runs inside WSL2 (a small Linux that is part of Windows). This installer will:`n`n 1. Check the installer files against their checksums.`n 2. Turn on WSL2 and install Ubuntu if they are missing (Windows may ask for a restart; this installer continues afterwards).`n 3. Create a Linux user for you inside Ubuntu (no password; Ubuntu is reachable only from your Windows account).`n 4. Run the normal Linux installer inside Ubuntu: a locked-down 'bwsafe' user, root-owned programs, one sudo rule, and a checksum-verified Bitwarden CLI.`n`nWindows will now ask for administrator permission to turn on WSL.`n`nContinue?" "OKCancel"
  if ($r -ne "OK") { exit 1 }
  $argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$Self`"", "-Distro", $Distro)
  if ($Expect) { $argsList += @("-Expect", $Expect) }
  Start-Process powershell -Verb RunAs -ArgumentList $argsList
  exit 0
}

# 2. Verify the files before anything runs (same SHA256SUMS the Linux installer uses; files must have LF line endings).
$sums = Join-Path $Skill "SHA256SUMS"
if (-not (Test-Path $sums)) { Say "SHA256SUMS is missing, so the files cannot be verified. Download the skill again from the official place."; exit 1 }
$sumsHash = (Get-FileHash $sums -Algorithm SHA256).Hash.ToLower()
if ($Expect -and $Expect.ToLower() -ne $sumsHash) { Say "The SHA256SUMS fingerprint does not match the one you gave.`nyours:  $Expect`nactual: $sumsHash`nDo not install."; exit 1 }
foreach ($line in Get-Content $sums) {
  $h, $f = $line -split "\s+", 2; $f = $f.TrimStart("*")
  $p = Join-Path $Skill $f
  if (-not (Test-Path $p) -or (Get-FileHash $p -Algorithm SHA256).Hash.ToLower() -ne $h) {
    Say "File '$f' does not match SHA256SUMS (changed, damaged, or converted to Windows line endings). Nothing was installed.`nDownload the skill again (git: keep LF endings)."; exit 1
  }
}

# 3. WSL2 + Ubuntu.
$wslOk = $false
try { & wsl.exe --status *> $null; $wslOk = ($LASTEXITCODE -eq 0) } catch {}
if (-not $wslOk -or -not (Distro-Installed)) {
  # Come back after a restart.
  Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" "OpenClawBitwarden" ("powershell -NoProfile -ExecutionPolicy Bypass -File `"$Self`" -Resume -Distro $Distro" + $(if ($Expect) { " -Expect $Expect" } else { "" }))
  & wsl.exe --install -d $Distro --no-launch
  $code = $LASTEXITCODE
  if (-not (Distro-Installed)) {
    Say "WSL was turned on, but Windows needs a restart to finish. After you restart and sign in, this installer continues by itself.`n`nIf nothing happens, check that virtualization is enabled in the BIOS/UEFI (often called Intel VT-x, AMD-V or SVM)."
    exit 0
  }
}
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" "OpenClawBitwarden" -ErrorAction SilentlyContinue
& wsl.exe --set-version $Distro 2 *> $null

# Dialogs need WSLg (Windows 11, or recent Windows 10 with an updated WSL).
& wsl.exe -d $Distro -u root -- test -d /mnt/wslg
if ($LASTEXITCODE -ne 0) {
  Say "This Windows/WSL has no WSLg, so the Approve and password windows cannot appear. Run 'wsl --update' in a terminal (Windows 10 needs 21H2 or later), then run this installer again."; exit 1
}

# 4. Linux user (reuses your Windows name, no password), systemd on (needed for /run/bwsafe), packages.
$user = ($env:USERNAME.ToLower() -replace "[^a-z0-9_-]", "")
if (-not $user -or $user -notmatch "^[a-z]") { $user = "user" }
$setup = @"
set -e
id $user >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $user && passwd -d $user >/dev/null
printf '[boot]\nsystemd=true\n[user]\ndefault=%s\n' $user > /etc/wsl.conf
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bubblewrap jq zenity x11-xserver-utils curl unzip ca-certificates sudo
"@
$setup = $setup -replace "`r", ""
& wsl.exe -d $Distro -u root -- bash -c $setup
if ($LASTEXITCODE -ne 0) { Say "Preparing Ubuntu failed. Open Ubuntu once from the Start menu, check the network, and run this installer again."; exit 1 }
& wsl.exe --terminate $Distro      # restart so systemd and the default user take effect
& wsl.exe -d $Distro -u root -- true

# 5. Copy the verified files into Ubuntu and run the Linux installer as that user, with a temporary passwordless sudo that is removed afterwards.
$winPath = $Skill
$run = @"
set -e
rm -rf /opt/bwsafe-src && mkdir -p /opt/bwsafe-src && cp -r "`$(wslpath '$winPath')"/. /opt/bwsafe-src/
chown -R root:root /opt/bwsafe-src
printf '%s ALL=(ALL) NOPASSWD: ALL\n' $user > /etc/sudoers.d/zz-bwsafe-install-temp && chmod 440 /etc/sudoers.d/zz-bwsafe-install-temp
"@ -replace "`r", ""
& wsl.exe -d $Distro -u root -- bash -c $run
if ($LASTEXITCODE -ne 0) { Say "Copying the installer into Ubuntu failed."; exit 1 }
$exp = if ($Expect) { "--expect $Expect" } else { "" }
try {
  & wsl.exe -d $Distro -u $user -- bash -lc "export DISPLAY=:0; bash /opt/bwsafe-src/install/install.sh $exp"
  $rc = $LASTEXITCODE
} finally {
  & wsl.exe -d $Distro -u root -- rm -f /etc/sudoers.d/zz-bwsafe-install-temp
}
if ($rc -ne 0) { Say "The Linux installer inside Ubuntu did not finish (exit $rc). Run this installer again; nothing important is half-configured."; exit 1 }

# 6. A Windows-side shortcut to the client.
$cmd = Join-Path $env:USERPROFILE "bwsafe.cmd"
Set-Content $cmd "@wsl.exe -d $Distro -u $user -- bwsafe %*" -Encoding ASCII
Say "Installed.`n`nNext, in a normal Command Prompt or PowerShell run:`n  bwsafe setup`nWindows will ask which Bitwarden server you use, then your API key, master password and the permission tick-boxes.`n`n(The command is the file $cmd. Your agent should run 'wsl -d $Distro -- bwsafe ...' or this file.)"
