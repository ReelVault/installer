<#
.SYNOPSIS
    ReelVault installer for Windows.

.DESCRIPTION
    Composes the installation from the latest (or pinned) releases of the two
    component repositories - the server from ReelVault/reelvault and the web UI
    from ReelVault/website - verifying the published SHA256 checksums, installs
    everything under your user profile, installs ffmpeg when missing, and
    creates a Start Menu shortcut. This repository never needs a new release
    when a component ships an update.
    The web UI and API are served on one port (default 3030):
        http://localhost:3030

.EXAMPLE
    .\install.ps1                          # latest server + web, defaults
    .\install.ps1 -Remote                  # reachable from other devices on the LAN
    .\install.ps1 -Port 8080               # custom port
    .\install.ps1 -Autostart               # start ReelVault when you sign in
    .\install.ps1 -Upgrade                 # update an existing install (keeps data)
    .\install.ps1 -Full                    # force a static ffmpeg/ffprobe into bin\
    .\install.ps1 -Version v1.0.1          # pin the server release
    .\install.ps1 -WebVersion v0.2.0       # pin the web release
    .\install.ps1 -ServerFile .\server.tar.gz -WebFile .\web.zip   # local artifacts
    .\install.ps1 -Uninstall               # remove files and shortcuts (-Purge deletes data)
#>
[CmdletBinding()]
param(
	[switch]$Remote,
	[int]$Port = 3030,
	[string]$Dir = "$env:LOCALAPPDATA\ReelVault",
	[string]$Version = "",
	[string]$WebVersion = "",
	[string]$ServerFile = "",
	[string]$WebFile = "",
	[switch]$Autostart,
	[switch]$Upgrade,
	[switch]$Full,
	[switch]$NoShortcut,
	[switch]$Uninstall,
	[switch]$Purge
)

$ErrorActionPreference = "Stop"
$ServerRepo = "ReelVault/reelvault"
$WebRepo = "ReelVault/website"
$StartMenuDir = [Environment]::GetFolderPath("Programs")
$ShortcutPath = Join-Path $StartMenuDir "ReelVault.lnk"
$StartupShortcutPath = Join-Path $StartMenuDir "Programs\Startup\ReelVault.lnk"

function Write-Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }
function Write-Warn2($message) { Write-Host "warning: $message" -ForegroundColor Yellow }

function Get-LatestTag($repo) {
	$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing
	return $release.tag_name
}

function Get-Sha256($path) {
	(Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

function Assert-Checksum($repo, $tag, $asset, $path) {
	$sumsUrl = "https://github.com/$repo/releases/download/$tag/SHA256SUMS.txt"
	$sums = Join-Path $env:TEMP "sums-$asset"
	try {
		Invoke-WebRequest -Uri $sumsUrl -OutFile $sums -UseBasicParsing
	} catch {
		Write-Warn2 "could not download SHA256SUMS.txt for $asset - skipping the checksum verification"
		return
	}

	# Tolerate both "hash  name" and "hash  ./name" lines.
	$pattern = "^[0-9a-fA-F]{64}\s+\*?(\./)?" + [regex]::Escape($asset) + "\s*$"
	$line = (Get-Content $sums) | Where-Object { $_ -match $pattern } | Select-Object -First 1
	if (-not $line) { throw "SHA256SUMS.txt of $repo $tag has no entry for $asset - refusing to install" }

	$expected = ($line -split "\s+")[0].ToLower()
	$actual = Get-Sha256 $path
	if ($actual -ne $expected) { throw "$asset failed the SHA256 check (expected $expected, got $actual)" }
	Write-Step "Checksum verified: $asset"
}

function Stop-ReelVaultProcesses {
	$here = $Dir
	Get-Process bun -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$here*" } | ForEach-Object {
		Write-Step "Stopping running ReelVault (pid $($_.Id))…"
		Stop-Process -Id $_.Id -Force
	}
}

function Remove-Shortcuts {
	foreach ($path in @($ShortcutPath, $StartupShortcutPath)) {
		if (Test-Path $path) { Remove-Item $path -Force }
	}
}

function New-ReelVaultShortcut($targetPath) {
	$shell = New-Object -ComObject WScript.Shell
	$shortcut = $shell.CreateShortcut($ShortcutPath)
	$shortcut.TargetPath = $targetPath
	$shortcut.WorkingDirectory = $Dir
	$shortcut.Description = "ReelVault media server"
	$shortcut.Save()
}

if ($Uninstall) {
	Stop-ReelVaultProcesses
	Remove-Shortcuts
	if (Test-Path $Dir) {
		if ($Purge) {
			Write-Step "Removing $Dir (including data)…"
			Remove-Item $Dir -Recurse -Force
		} else {
			Write-Step "Removing application files from $Dir (data\ is kept)…"
			foreach ($name in @("bun", "server", "web", "bin", "start.bat", "settings.cmd", "README.txt")) {
				$path = Join-Path $Dir $name
				if (Test-Path $path) { Remove-Item $path -Recurse -Force }
			}
		}
	}
	Write-Host ""
	Write-Host "ReelVault uninstalled." -ForegroundColor Green
	exit 0
}

function Install-FfmpegStatic {
	# winget is unavailable — fetch a static build into .\bin, which start.bat
	# puts on the PATH.
	Write-Step "Downloading a static ffmpeg build…"
	$binDir = Join-Path $Dir "bin"
	$zip = Join-Path $env:TEMP "ffmpeg-release-essentials.zip"
	Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $zip -UseBasicParsing
	$extract = Join-Path $env:TEMP ("ffmpeg-extract-" + [guid]::NewGuid().ToString("N"))
	Expand-Archive -Path $zip -DestinationPath $extract -Force
	New-Item -ItemType Directory -Force -Path $binDir | Out-Null
	Copy-Item (Join-Path $extract "ffmpeg-*-essentials_build\bin\ffmpeg.exe") $binDir -Force
	Copy-Item (Join-Path $extract "ffmpeg-*-essentials_build\bin\ffprobe.exe") $binDir -Force
	Remove-Item $extract -Recurse -Force
	Remove-Item $zip -Force
	Write-Host "    ffmpeg installed to $binDir."
}

# ── Server component ─────────────────────────────────────────────────────────
$serverTag = if ($Version -ne "") { "v" + $Version.TrimStart("v") } else { Get-LatestTag $ServerRepo }
$serverAsset = "ReelVault-Server-$($serverTag.TrimStart('v'))-windows-x64.zip"

if ($ServerFile -ne "") {
	if (-not (Test-Path $ServerFile)) { throw "server archive not found: $ServerFile" }
	$serverArchivePath = $ServerFile
} else {
	Write-Step "Downloading server $serverTag…"
	$url = "https://github.com/$ServerRepo/releases/download/$serverTag/$serverAsset"
	$serverArchivePath = Join-Path $env:TEMP $serverAsset
	Write-Host "    $url"
	Invoke-WebRequest -Uri $url -OutFile $serverArchivePath -UseBasicParsing
	Assert-Checksum $ServerRepo $serverTag $serverAsset $serverArchivePath
}

# ── Web component ────────────────────────────────────────────────────────────
$webTag = if ($WebVersion -ne "") { "v" + $WebVersion.TrimStart("v") } else { Get-LatestTag $WebRepo }
$webAsset = "reelvault-web-$($webTag.TrimStart('v')).zip"

if ($WebFile -ne "") {
	if (-not (Test-Path $WebFile)) { throw "web release not found: $WebFile" }
	$webArchivePath = $WebFile
} else {
	Write-Step "Downloading web UI $webTag…"
	$url = "https://github.com/$WebRepo/releases/download/$webTag/$webAsset"
	$webArchivePath = Join-Path $env:TEMP $webAsset
	Write-Host "    $url"
	Invoke-WebRequest -Uri $url -OutFile $webArchivePath -UseBasicParsing
	Assert-Checksum $WebRepo $webTag $webAsset $webArchivePath
}

# ── Compose the application layout ───────────────────────────────────────────
Write-Step "Installing to $Dir…"
$extractDir = Join-Path $env:TEMP ("reelvault-extract-" + [guid]::NewGuid().ToString("N"))
Expand-Archive -Path $serverArchivePath -DestinationPath $extractDir -Force
if (-not (Test-Path (Join-Path $extractDir "ReelVault\server"))) { throw "the server archive has an unexpected layout (no ReelVault\server)" }
$webExtractDir = Join-Path $extractDir "ReelVault\web"
Expand-Archive -Path $webArchivePath -DestinationPath $webExtractDir -Force
if (-not (Test-Path (Join-Path $webExtractDir "index.html"))) { throw "the web release has an unexpected layout (no index.html at its root)" }

if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
Stop-ReelVaultProcesses
Copy-Item -Path (Join-Path $extractDir "ReelVault\*") -Destination $Dir -Recurse -Force
Remove-Item $extractDir -Recurse -Force
if ($ServerFile -eq "") { Remove-Item $serverArchivePath -Force }
if ($WebFile -eq "") { Remove-Item $webArchivePath -Force }

Write-Step "Setting up ffmpeg…"
if ($Full) {
	# --full: a static pair pinned inside bin\ takes precedence over any system package.
	Install-FfmpegStatic
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
	Write-Host "    ffmpeg already installed."
} elseif (Get-Command winget -ErrorAction SilentlyContinue) {
	winget install --id Gyan.FFmpeg -e --silent --accept-source-agreements --accept-package-agreements
	Write-Warn2 "If the server cannot find ffmpeg, sign out and back in (PATH refresh)."
} else {
	Install-FfmpegStatic
}

Write-Step "Writing settings (port $Port$(if ($Remote) { ", LAN access" })…"
$settings = "@echo off`r`n"
$settings += 'set "APP_PORT=' + $Port + '"' + "`r`n"
if ($Remote) { $settings += 'set "APP_HOST=0.0.0.0"' + "`r`n" }
Set-Content -Path (Join-Path $Dir "settings.cmd") -Value $settings -Encoding ASCII

if (-not $NoShortcut) {
	Write-Step "Creating Start Menu shortcut…"
	New-ReelVaultShortcut (Join-Path $Dir "start.bat")
	if ($Autostart) {
		Copy-Item $ShortcutPath $StartupShortcutPath -Force
	}
}

if ($Remote) {
	Write-Warn2 "Allow port $Port in Windows Firewall if other devices cannot connect:"
	Write-Host "    netsh advfirewall firewall add rule name=`"ReelVault`" dir=in action=allow protocol=TCP localport=$Port"
}

Write-Host ""
Write-Host "  ReelVault is installed." -ForegroundColor Green
Write-Host ""
Write-Host "    Address:  http://localhost:$Port"
Write-Host "    Data:     $Dir\data"
Write-Host "    Start:    Start Menu → ReelVault  (or $Dir\start.bat)"
Write-Host ""
Write-Host "  Open the address above and create the administrator account."
Write-Host ""
