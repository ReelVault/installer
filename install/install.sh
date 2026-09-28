#!/usr/bin/env bash
# ReelVault installer for Linux.
#
# Composes the installation from the latest (or pinned) releases of the two
# component repositories — the server from ReelVault/reelvault and the web UI
# from ReelVault/website — verifying the published SHA256 checksums, installs
# everything under your home directory and (on systemd distros) registers a
# user service that starts on login/boot. This repository never needs a new
# release when a component ships an update.
#
# Usage:
#   ./install.sh                          # latest server + web, default settings
#   ./install.sh --remote                 # reachable from other devices on the LAN
#   ./install.sh --port 8080              # custom port
#   ./install.sh --dir /srv/reelvault     # custom install directory
#   ./install.sh --version v1.0.1         # pin the server release
#   ./install.sh --web-version v0.2.0     # pin the web release
#   ./install.sh --server-file ./server.tar.gz --web-file ./web.zip   # local artifacts
#   ./install.sh --full                   # force a static ffmpeg/ffprobe into bin/
#   ./install.sh --upgrade                # update an existing install (keeps data)
#   ./install.sh --uninstall              # remove the service and files (--purge deletes data)
#
# The web UI and API are served on one port (default 3030):
#   http://localhost:3030
set -euo pipefail

SERVER_REPO="ReelVault/reelvault"
WEB_REPO="ReelVault/website"
DEFAULT_DIR="${HOME}/.local/share/reelvault"
VERSION=""
WEB_VERSION=""
SERVER_FILE=""
WEB_FILE=""
TARGET_DIR=""
PORT="3030"
REMOTE="false"
NO_SERVICE="false"
UNINSTALL="false"
PURGE="false"
UPGRADE="false"
FULL="false"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--web-version) WEB_VERSION="${2:?}"; shift 2 ;;
		--server-file) SERVER_FILE="${2:?}"; shift 2 ;;
		--web-file) WEB_FILE="${2:?}"; shift 2 ;;
		--dir) TARGET_DIR="${2:?}"; shift 2 ;;
		--port) PORT="${2:?}"; shift 2 ;;
		--remote) REMOTE="true"; shift ;;
		--no-service) NO_SERVICE="true"; shift ;;
		--uninstall) UNINSTALL="true"; shift ;;
		--purge) PURGE="true"; shift ;;
		--upgrade) UPGRADE="true"; shift ;;
		--full) FULL="true"; shift ;;
		-h | --help)
			sed -n '2,22p' "${BASH_SOURCE[0]}"
			exit 0
			;;
		*) die "unknown option: $1 (see --help)" ;;
	esac
done

SERVICE_NAME="reelvault"
SERVICE_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user/${SERVICE_NAME}.service"
SERVICE_ACTIVE="false"

detect_service() {
	if command -v systemctl >/dev/null 2>&1 && [[ -f "${SERVICE_FILE}" ]]; then
		SERVICE_ACTIVE="true"
	fi
}

fetch() {
	local url="$1" out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL --retry 3 -o "$out" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$out" "$url"
	else
		die "need curl or wget to download files"
	fi
}

api_get() {
	local url="$1"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO- "$url"
	else
		die "need curl or wget to download files"
	fi
}

unzip_to() {
	local zip_file="$1" dest="$2"
	if command -v unzip >/dev/null 2>&1; then
		unzip -q "$zip_file" -d "$dest"
	elif command -v python3 >/dev/null 2>&1; then
		python3 -m zipfile -e "$zip_file" "$dest"
	else
		die "need unzip (or python3) to extract the web release"
	fi
}

sha256_of() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -d' ' -f1
	else
		shasum -a 256 "$file" | cut -d' ' -f1
	fi
}

# Verifies a downloaded artifact against the SHA256SUMS.txt published with its
# release. Skipped for --server-file/--web-file (nothing published to check).
verify_checksum() {
	local repo="$1" tag="$2" asset="$3" file="$4"
	if command -v python3 >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
		:
	else
		warn "no sha256 tool found — skipping the checksum verification"
		return 0
	fi

	local sums="${TMP}/sums-${asset}"
	fetch "https://github.com/${repo}/releases/download/${tag}/SHA256SUMS.txt" "$sums" || die "could not download SHA256SUMS.txt for ${asset} — refusing to install unverified"

	local expected
	expected="$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?${asset}\$" "${sums}" | cut -d' ' -f1 | head -1)"
	if [[ -z "$expected" ]]; then
		die "SHA256SUMS.txt of ${repo} ${tag} has no entry for ${asset} — refusing to install"
	fi

	local actual
	actual="$(sha256_of "$file")"
	if [[ "$actual" != "$expected" ]]; then
		die "${asset} failed the SHA256 check (expected ${expected}, got ${actual})"
	fi
	log "Checksum verified: ${asset}"
}

detect_arch() {
	case "$(uname -m)" in
		x86_64) echo "linux-x64" ;;
		aarch64 | arm64) echo "linux-arm64" ;;
		*) die "unsupported architecture: $(uname -m)" ;;
	esac
}

# Echoes the release tag for a repo: the pinned version or releases/latest.
resolve_tag() {
	local repo="$1" pinned="$2" name="$3"
	if [[ -n "$pinned" ]]; then
		echo "v${pinned#v}"

		return
	fi
	log "Resolving the latest ${name} release…"

	local tag
	tag="$(api_get "https://api.github.com/repos/${repo}/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
	[[ -n "$tag" ]] || die "could not resolve the latest ${name} release; pass an explicit version"
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "unexpected release tag: $tag"

	echo "$tag"
}

ffmpeg_available() {
	command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1
}

install_ffmpeg_system() {
	log "Installing ffmpeg (required for transcoding)…"
	if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi

	if command -v apt-get >/dev/null 2>&1; then
		$SUDO apt-get update -qq && $SUDO apt-get install -y ffmpeg
	elif command -v dnf >/dev/null 2>&1; then
		$SUDO dnf install -y ffmpeg
	elif command -v pacman >/dev/null 2>&1; then
		$SUDO pacman -Sy --noconfirm ffmpeg
	elif command -v zypper >/dev/null 2>&1; then
		$SUDO zypper --non-interactive install ffmpeg
	else
		return 1
	fi
}

# Static builds — for distros whose repositories do not ship ffmpeg (e.g. Fedora
# without RPM Fusion), for machines without root, and for --full installs.
# Installed into $BIN_DIR, which start.sh puts on the PATH.
install_ffmpeg_static() {
	case "$(uname -m)" in
		x86_64) local flavor="amd64" ;;
		aarch64 | arm64) local flavor="arm64" ;;
		*) return 1 ;;
	esac

	local url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${flavor}-static.tar.xz"
	log "Downloading a static ffmpeg build…"
	mkdir -p "$BIN_DIR"
	fetch "$url" "${TMP}/ffmpeg-static.tar.xz" || return 1
	tar -xJf "${TMP}/ffmpeg-static.tar.xz" -C "$TMP" || return 1

	local extracted
	extracted="$(find "$TMP" -maxdepth 1 -type d -name 'ffmpeg-*-static' | head -1)"
	[[ -n "$extracted" ]] || return 1

	cp "${extracted}/ffmpeg" "${extracted}/ffprobe" "$BIN_DIR/"
	chmod +x "$BIN_DIR/ffmpeg" "$BIN_DIR/ffprobe"
}

install_ffmpeg() {
	if ffmpeg_available; then
		log "ffmpeg already installed: $(ffmpeg -version 2>/dev/null | head -1)"
		return 0
	fi

	if install_ffmpeg_system && ffmpeg_available; then
		return 0
	fi

	warn "the system package manager could not provide ffmpeg (some distros need extra repositories)."

	if install_ffmpeg_static && "$BIN_DIR/ffmpeg" -version >/dev/null 2>&1; then
		log "Static ffmpeg installed to ${BIN_DIR}."
		return 0
	fi

	warn "Install ffmpeg manually (https://ffmpeg.org) and re-run this installer."
	die "ffmpeg is required"
}

uninstall() {
	detect_service
	if [[ "$SERVICE_ACTIVE" == "true" ]]; then
		log "Stopping and removing the systemd user service…"
		systemctl --user disable --quiet "${SERVICE_NAME}" 2>/dev/null || true
		systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
		rm -f "${SERVICE_FILE}"
		systemctl --user daemon-reload 2>/dev/null || true
	fi

	if [[ -n "$TARGET_DIR" && -d "$TARGET_DIR" ]]; then
		if [[ "$PURGE" == "true" ]]; then
			log "Removing ${TARGET_DIR} (including data)…"
			rm -rf "${TARGET_DIR}"
		else
			log "Removing application files from ${TARGET_DIR} (data/ is kept)…"
			rm -rf "${TARGET_DIR}/bun" "${TARGET_DIR}/server" "${TARGET_DIR}/web" "${TARGET_DIR}/bin" "${TARGET_DIR}/start.sh" "${TARGET_DIR}/settings.env" "${TARGET_DIR}/README.txt"
		fi
	fi

	log "ReelVault uninstalled."
}

if [[ "$UNINSTALL" == "true" ]]; then
	uninstall
	exit 0
fi

TARGET_DIR="${TARGET_DIR:-$DEFAULT_DIR}"
BIN_DIR="${TARGET_DIR}/bin"
ARCH="$(detect_arch)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "$FULL" == "true" ]]; then
	# --full: a static pair pinned inside bin/ takes precedence over any system package.
	if install_ffmpeg_static && "$BIN_DIR/ffmpeg" -version >/dev/null 2>&1; then
		log "Static ffmpeg installed to ${BIN_DIR}."
	else
		warn "the static ffmpeg download failed — falling back to the system package"
		install_ffmpeg
	fi
else
	install_ffmpeg
fi

# ── Server component ─────────────────────────────────────────────────────────
if [[ -n "$SERVER_FILE" ]]; then
	[[ -f "$SERVER_FILE" ]] || die "server archive not found: $SERVER_FILE"
	cp "$SERVER_FILE" "${TMP}/server.tar.gz"
else
	SERVER_TAG="$(resolve_tag "$SERVER_REPO" "$VERSION" "server")"
	SERVER_ASSET="ReelVault-Server-${SERVER_TAG#v}-${ARCH}.tar.gz"
	log "Downloading server ${SERVER_TAG}…"
	fetch "https://github.com/${SERVER_REPO}/releases/download/${SERVER_TAG}/${SERVER_ASSET}" "${TMP}/server.tar.gz"
	verify_checksum "$SERVER_REPO" "$SERVER_TAG" "$SERVER_ASSET" "${TMP}/server.tar.gz"
fi

# ── Web component ────────────────────────────────────────────────────────────
if [[ -n "$WEB_FILE" ]]; then
	[[ -f "$WEB_FILE" ]] || die "web release not found: $WEB_FILE"
	cp "$WEB_FILE" "${TMP}/web.zip"
else
	WEB_TAG="$(resolve_tag "$WEB_REPO" "$WEB_VERSION" "web")"
	WEB_ASSET="reelvault-web-${WEB_TAG#v}.zip"
	log "Downloading web UI ${WEB_TAG}…"
	fetch "https://github.com/${WEB_REPO}/releases/download/${WEB_TAG}/${WEB_ASSET}" "${TMP}/web.zip"
	verify_checksum "$WEB_REPO" "$WEB_TAG" "$WEB_ASSET" "${TMP}/web.zip"
fi

# ── Compose the application layout ───────────────────────────────────────────
log "Extracting…"
tar -xzf "${TMP}/server.tar.gz" -C "$TMP"
[[ -d "${TMP}/ReelVault/server" ]] || die "the server archive has an unexpected layout (no ReelVault/server)"
unzip_to "${TMP}/web.zip" "${TMP}/ReelVault/web"
[[ -f "${TMP}/ReelVault/web/index.html" ]] || die "the web release has an unexpected layout (no index.html at its root)"

mkdir -p "$TARGET_DIR"
log "Installing to ${TARGET_DIR}…"
rm -rf "$TARGET_DIR/server" "$TARGET_DIR/web" "$TARGET_DIR/bun"
cp -a "${TMP}/ReelVault/." "$TARGET_DIR/"
chmod +x "$TARGET_DIR/start.sh" "$TARGET_DIR/bun/bun"

if [[ "$FULL" == "true" ]]; then
	[[ -x "${BIN_DIR}/ffmpeg" && -x "${BIN_DIR}/ffprobe" ]] ||
		die "--full did not produce bin/ffmpeg and bin/ffprobe"
	log "Using the static ffmpeg/ffprobe from ${BIN_DIR}."
fi

# Single source of overrides for both the manual launcher and systemd.
HOST_BIND="127.0.0.1"
[[ "$REMOTE" == "true" ]] && HOST_BIND="0.0.0.0"
cat >"${TARGET_DIR}/settings.env" <<EOF
export APP_HOST="${HOST_BIND}"
export APP_PORT="${PORT}"
EOF

if [[ "$NO_SERVICE" == "true" ]] || ! command -v systemctl >/dev/null 2>&1; then
	if [[ "$NO_SERVICE" != "true" ]]; then
		warn "systemd not found — start ReelVault manually: ${TARGET_DIR}/start.sh"
	fi
	log "Done. Open http://localhost:${PORT} and create the administrator account."
	exit 0
fi

log "Creating the systemd user service…"
mkdir -p "$(dirname "${SERVICE_FILE}")"

cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=ReelVault media server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${TARGET_DIR}
EnvironmentFile=${TARGET_DIR}/settings.env
ExecStart=${TARGET_DIR}/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# A systemctl binary without a running user bus (containers, sudo shells) is
# not a failure — fall back to the manual launcher.
if ! systemctl --user daemon-reload 2>/dev/null; then
	warn "systemd user session is not available — start ReelVault manually: ${TARGET_DIR}/start.sh"
	log "Done. Open http://localhost:${PORT} and create the administrator account."
	exit 0
fi

systemctl --user enable --now "${SERVICE_NAME}" 2>/dev/null || warn "could not enable the service — start manually: ${TARGET_DIR}/start.sh"

sleep 2
if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
	log "ReelVault is running."
else
	warn "service did not report active yet — check: journalctl --user -u ${SERVICE_NAME}"
fi

cat <<EOF

  ReelVault is installed.

    Address:  http://localhost:${PORT}
    Data:     ${TARGET_DIR}/data
    Service:  systemctl --user status|start|stop|restart ${SERVICE_NAME}

  Open the address above and create the administrator account.
  To reach the server from other devices, re-run with --remote
  and open port ${PORT} in your firewall.
EOF
