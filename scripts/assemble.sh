#!/usr/bin/env bash
# ReelVault bundle assembler — combines released component artifacts into the
# classic fresh-install archives.
#
# Downloads the SERVER release archive from ReelVault/reelvault and the WEB
# release zip from ReelVault/website, then repacks them per platform into the
# combined layout the installers expect (ReelVault/{bun, server, web, start.*}).
# With --full, a pinned static ffmpeg/ffprobe pair is added into bin/ — no
# component release ever carries ffmpeg, only bundles do.
#
# Nothing is built from source: a bundle is exactly what the admin panel would
# download as separate component updates, just packed together.
#
# Usage:
#   ./scripts/assemble.sh <server-version> <web-version> [options]
#
# Examples:
#   ./scripts/assemble.sh 1.0.0 0.2.0
#   ./scripts/assemble.sh 1.0.0 0.2.0 --full
#   ./scripts/assemble.sh 1.0.0 0.2.0 --server-archive ./ReelVault-Server-1.0.0-linux-x64.tar.gz
#
# Options:
#   --full                    Add the pinned static ffmpeg/ffprobe pair (bin/)
#   --server-archive <file>   Use a local server archive instead of downloading
#                             (repeatable; platform matched by file name —
#                             unmatched platforms still download, or combine
#                             with --skip-checksums for not-yet-published files)
#   --web-zip <file>          Use a local web zip instead of downloading
#   --skip-checksums          Skip SHA256 verification against the published
#                             SHA256SUMS.txt (for not-yet-published local files)
#   --out <dir>               Output directory (default: dist/bundles)
#   -h, --help                Show this help
#
# Environment:
#   FFMPEG_CACHE     Pinned ffmpeg build cache (default: dist/cache/ffmpeg)
#
# Bundle naming: ReelVault-<serverV>-web<webV>-<platform>[-full], released on
# ReelVault/installer under the tag v<serverV>-web<webV>.
set -euo pipefail

# Pinned static ffmpeg builds for the -full variant: <source>|<version>|<url>|<sha256>.
# Linux archives come from johnvansickle.com (rolling URLs — the SHA256 keeps
# them pinned); Windows comes from the immutable GyanD/codexffmpeg release tag.
FFMPEG_PINS=(
	"linux-amd64|7.0.2|https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz|abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67"
	"linux-arm64|7.0.2|https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz|f4149bb2b0784e30e99bdda85471c9b5930d3402014e934a5088b41d0f7201b1"
	"windows|8.1.2|https://github.com/GyanD/codexffmpeg/releases/download/8.1.2/ffmpeg-8.1.2-essentials_build.zip|db580001caa24ac104c8cb856cd113a87b0a443f7bdf47d8c12b1d740584a2ec"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_REPO="ReelVault/reelvault"
WEB_REPO="ReelVault/website"
FFMPEG_CACHE="${FFMPEG_CACHE:-$REPO_ROOT/dist/cache/ffmpeg}"
OUT_DIR="$REPO_ROOT/dist/bundles"
FULL="false"
SKIP_CHECKSUMS="false"
SERVER_ARCHIVES=()
WEB_ZIP=""

usage() {
	awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

die() {
	echo "error: $*" >&2
	exit 1
}

SERVER_VERSION=""
WEB_VERSION=""
while [ $# -gt 0 ]; do
	case "$1" in
		--full) FULL="true"; shift ;;
		--skip-checksums) SKIP_CHECKSUMS="true"; shift ;;
		--server-archive)
			[ $# -ge 2 ] || die "--server-archive needs a value"
			SERVER_ARCHIVES+=("$2")
			shift 2
			;;
		--web-zip)
			[ $# -ge 2 ] || die "--web-zip needs a value"
			WEB_ZIP="$2"
			shift 2
			;;
		--out)
			[ $# -ge 2 ] || die "--out needs a value"
			OUT_DIR="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*) die "unknown option: $1" ;;
		*)
			if [ -z "$SERVER_VERSION" ]; then SERVER_VERSION="$1"; elif [ -z "$WEB_VERSION" ]; then WEB_VERSION="$1"; else die "unexpected extra argument: $1"; fi
			shift
			;;
	esac
done

[ -n "$SERVER_VERSION" ] && [ -n "$WEB_VERSION" ] || { usage; die "need both versions: ./scripts/assemble.sh <server-version> <web-version>"; }

SERVER_VERSION="${SERVER_VERSION#v}"
WEB_VERSION="${WEB_VERSION#v}"
[[ "$SERVER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "server version must look like 1.2.3 (got '$SERVER_VERSION')"
[[ "$WEB_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "web version must look like 0.2.3 (got '$WEB_VERSION')"

for tool in curl tar unzip sha256sum; do
	command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

if command -v zip >/dev/null; then
	ZIP_DIR() { (cd "$(dirname "$2")" && zip -qr "$1" "$(basename "$2")"); }
elif command -v 7z >/dev/null; then
	ZIP_DIR() { (cd "$(dirname "$2")" && 7z a -tzip -mx=9 "$1" "$(basename "$2")" >/dev/null); }
elif command -v python3 >/dev/null; then
	ZIP_DIR() { python3 -m zipfile -c "$1" "$2"; }
else
	die "creating the Windows .zip needs one of: zip, 7z, python3"
fi

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"
mkdir -p "$FFMPEG_CACHE"

BUNDLE_BASE="ReelVault-${SERVER_VERSION}-web${WEB_VERSION}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reelvault-assemble.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fetch() { curl -fsSL -o "$2" "$1"; }

# Echoes "<version>|<url>|<sha256>" for a pinned ffmpeg source.
ffmpeg_pin() { # <source>
	local pin
	for pin in "${FFMPEG_PINS[@]}"; do
		if [ "${pin%%|*}" = "$1" ]; then
			echo "${pin#*|}"

			return 0
		fi
	done
	die "no ffmpeg pin for '$1' (add it to FFMPEG_PINS in ${BASH_SOURCE[0]})"
}

# Downloads a release asset from a repo, or copies a provided local file.
get_asset() { # <repo> <version> <asset-name> <dest-file> <local-override>
	if [ -n "$5" ]; then
		[ -f "$5" ] || die "local file not found: $5"
		cp "$5" "$4"

		return
	fi
	fetch "https://github.com/$1/releases/download/v$2/$3" "$4"
}

# Verifies a downloaded artifact against the component's published SHA256SUMS.
verify_checksums() { # <repo> <version> <asset-name> <file>
	[ "$SKIP_CHECKSUMS" = "true" ] && return 0

	local sums="$WORK/sums-$3"
	fetch "https://github.com/$1/releases/download/v$2/SHA256SUMS.txt" "$sums"
	local expected
	expected="$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?$3\$" "$sums" | cut -d' ' -f1 | head -1)"
	[ -n "$expected" ] || die "SHA256SUMS.txt of $1 v$2 has no entry for $3"
	local actual
	actual="$(sha256sum "$4" | cut -d' ' -f1)"
	[ "$actual" = "$expected" ] || die "$3 failed the SHA256 check (expected $expected, got $actual)"
	echo "    verified: $3"
}

# Ensures a pinned, SHA256-verified ffmpeg/ffprobe pair and echoes its directory.
ensure_ffmpeg() { # <source> <version> <url> <sha256>
	local src="$1" version="$2" url="$3" sha256="$4"
	local dir="$FFMPEG_CACHE/$version/$src"
	local archive="$FFMPEG_CACHE/$version/$(basename "$url")"
	local suffix=""
	[ "$src" = windows ] && suffix=".exe"

	if [ -f "$dir/.complete" ] && [ "$(cat "$dir/.complete")" = "$version $sha256" ] && [ -f "$dir/ffmpeg$suffix" ] && [ -f "$dir/ffprobe$suffix" ]; then
		echo "$dir"

		return
	fi

	mkdir -p "$FFMPEG_CACHE/$version"
	if [ ! -f "$archive" ]; then
		echo "    downloading ffmpeg ${version} (${src})…" >&2
		fetch "$url" "${archive}.part"
		mv "${archive}.part" "$archive"
	fi

	local actual
	actual="$(sha256sum "$archive" | cut -d' ' -f1)"
	[ "$actual" = "$sha256" ] || die "$(basename "$archive") failed the SHA256 check — if the pin was bumped on purpose, delete the cached archive"

	local tmp="$WORK/ffmpeg-$src"
	rm -rf "$tmp" "$dir"
	mkdir -p "$tmp" "$dir"
	if [ "$src" = windows ]; then unzip -q -o "$archive" -d "$tmp"; else tar -xf "$archive" -C "$tmp"; fi

	local binary
	binary="$(find "$tmp" -type f -name "ffmpeg$suffix" -print -quit)"
	[ -n "$binary" ] || die "unexpected ffmpeg archive layout in $(basename "$archive")"
	local bindir
	bindir="$(dirname "$binary")"
	[ -f "$bindir/ffprobe$suffix" ] || die "unexpected ffmpeg archive layout in $(basename "$archive") (no ffprobe)"
	cp "$bindir/ffmpeg$suffix" "$bindir/ffprobe$suffix" "$dir/"
	[ "$src" = windows ] || chmod +x "$dir/ffmpeg" "$dir/ffprobe"

	[ -n "$(find "$tmp" -maxdepth 1 -type d -name "*$version*" -print -quit)" ] ||
		die "expected ffmpeg ${version} in $(basename "$archive") — check FFMPEG_PINS in ${BASH_SOURCE[0]}"

	printf '%s %s\n' "$version" "$sha256" >"$dir/.complete"
	echo "$dir"
}

echo "==> Assembling bundle ${BUNDLE_BASE}"
echo "    server:  ${SERVER_VERSION} (${SERVER_REPO})"
echo "    web:     ${WEB_VERSION} (${WEB_REPO})"
echo "    full:    ${FULL}"

echo "==> Fetching component artifacts"
LINUX_X64_ARCHIVE="$WORK/server-linux-x64.tar.gz"
LINUX_ARM64_ARCHIVE="$WORK/server-linux-arm64.tar.gz"
WINDOWS_ARCHIVE="$WORK/server-windows-x64.zip"
# Each --server-archive override applies to the platform matched by file name.
for archive in "${SERVER_ARCHIVES[@]:-}"; do
	[ -n "$archive" ] || continue
	case "$(basename "$archive")" in
		*linux-x64*) LINUX_X64_ARCHIVE="$archive" ;;
		*linux-arm64*) LINUX_ARM64_ARCHIVE="$archive" ;;
		*windows-x64*) WINDOWS_ARCHIVE="$archive" ;;
		*) die "cannot match --server-archive to a platform: $archive" ;;
	esac
done
get_asset "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-linux-x64.tar.gz" "$WORK/server-linux-x64.tar.gz" "$LINUX_X64_ARCHIVE"
get_asset "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-linux-arm64.tar.gz" "$WORK/server-linux-arm64.tar.gz" "$LINUX_ARM64_ARCHIVE"
get_asset "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-windows-x64.zip" "$WORK/server-windows-x64.zip" "$WINDOWS_ARCHIVE"
get_asset "$WEB_REPO" "$WEB_VERSION" "reelvault-web-${WEB_VERSION}.zip" "$WORK/web.zip" "$WEB_ZIP"

echo "==> Verifying checksums"
verify_checksums "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-linux-x64.tar.gz" "$WORK/server-linux-x64.tar.gz"
verify_checksums "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-linux-arm64.tar.gz" "$WORK/server-linux-arm64.tar.gz"
verify_checksums "$SERVER_REPO" "$SERVER_VERSION" "ReelVault-Server-${SERVER_VERSION}-windows-x64.zip" "$WORK/server-windows-x64.zip"
verify_checksums "$WEB_REPO" "$WEB_VERSION" "reelvault-web-${WEB_VERSION}.zip" "$WORK/web.zip"

echo "==> Extracting web dist"
WEB_STAGE="$WORK/web"
rm -rf "$WEB_STAGE"
mkdir -p "$WEB_STAGE"
unzip -q "$WORK/web.zip" -d "$WEB_STAGE"
[ -f "$WEB_STAGE/index.html" ] || die "the web zip has no index.html at its root — wrong artifact?"

# name|server-archive|kind|ffmpeg-source
TARGETS=(
	"linux-x64|$WORK/server-linux-x64.tar.gz|tar|linux-amd64"
	"linux-arm64|$WORK/server-linux-arm64.tar.gz|tar|linux-arm64"
	"windows-x64|$WORK/server-windows-x64.zip|zip|windows"
)

# The -full variant keeps distinct file names so both variants of the same
# component pair can live side by side (and in one release).
VARIANT_SUFFIX=""
[ "$FULL" = "true" ] && VARIANT_SUFFIX="-full"

for TARGET in "${TARGETS[@]}"; do
	IFS='|' read -r NAME ARCHIVE KIND FFMPEG_SRC <<<"$TARGET"
	echo "==> Assembling ${NAME}"

	APP="$WORK/$NAME/ReelVault"
	rm -rf "$WORK/$NAME"
	mkdir -p "$WORK/$NAME"
	if [ "$KIND" = tar ]; then
		tar -xzf "$ARCHIVE" -C "$WORK/$NAME"
	else
		unzip -q "$ARCHIVE" -d "$WORK/$NAME"
	fi
	[ -d "$APP/server" ] || die "the server archive for $NAME has an unexpected layout (no ReelVault/server)"

	# Web UI from the web release — never bundled in component archives.
	rm -rf "$APP/web"
	cp -a "$WEB_STAGE" "$APP/web"

	if [ "$FULL" = "true" ]; then
		mkdir -p "$APP/bin"
		FFMPEG_PIN="$(ffmpeg_pin "$FFMPEG_SRC")"
		IFS='|' read -r FFMPEG_VERSION FFMPEG_URL FFMPEG_SHA256 <<<"$FFMPEG_PIN"
		FFMPEG_DIR="$(ensure_ffmpeg "$FFMPEG_SRC" "$FFMPEG_VERSION" "$FFMPEG_URL" "$FFMPEG_SHA256")"
		if [ "$FFMPEG_SRC" = windows ]; then
			cp "$FFMPEG_DIR/ffmpeg.exe" "$FFMPEG_DIR/ffprobe.exe" "$APP/bin/"
		else
			cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$APP/bin/"
			chmod +x "$APP/bin/ffmpeg" "$APP/bin/ffprobe"
		fi
	fi

	if [ "$KIND" = tar ]; then
		out="$OUT_DIR/${BUNDLE_BASE}-${NAME}${VARIANT_SUFFIX}.tar.gz"
		tar -czf "$out" -C "$WORK/$NAME" ReelVault
	else
		out="$OUT_DIR/${BUNDLE_BASE}-${NAME}${VARIANT_SUFFIX}.zip"
		ZIP_DIR "$out" "$APP"
	fi
	echo "    -> $(basename "$out")"
done

# Bare names in SHA256SUMS.txt: install.sh and the update service match exactly.
echo "==> Checksums"
(
	cd "$OUT_DIR"
	shopt -s nullglob
	files=( "${BUNDLE_BASE}"-*.tar.gz "${BUNDLE_BASE}"-*.zip )
	[ "${#files[@]}" -eq "${#TARGETS[@]}" ] || { echo "error: expected ${#TARGETS[@]} bundles, found ${#files[@]}" >&2; exit 1; }
	sha256sum "${files[@]}" >SHA256SUMS.txt
)

echo
echo "Done. Bundle assets are in ${OUT_DIR}:"
ls -1 "$OUT_DIR"
echo
echo "Upload the files to a GitHub release of ReelVault/installer, e.g.:"
echo "  gh release create v${SERVER_VERSION}-web${WEB_VERSION} --repo ReelVault/installer --title \"ReelVault v${SERVER_VERSION} + web v${WEB_VERSION}\" --generate-notes \"${OUT_DIR}\"/${BUNDLE_BASE}-*.tar.gz \"${OUT_DIR}\"/${BUNDLE_BASE}-*.zip \"${OUT_DIR}\"/SHA256SUMS.txt"
