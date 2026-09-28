#!/usr/bin/env bash
# Builds the ReelVault Docker image from the released component artifacts.
#
# Downloads the linux-x64 SERVER archive from ReelVault/reelvault and the WEB
# zip from ReelVault/website (verifying the published SHA256 checksums),
# unpacks them into a build context and runs `docker build`. The image runs
# exactly what the admin panel ships as updates — no source builds.
#
# The image is built locally; push it to any registry of your choice.
#
# Usage:
#   ./scripts/build-docker.sh <server-version> <web-version> [options]
#
# Examples:
#   ./scripts/build-docker.sh 1.0.1 0.2.0
#   ./scripts/build-docker.sh 1.0.1 0.2.0 --tag ghcr.io/reelvault/server:v1.0.1
#
# Options:
#   --tag <name:tag>        Image tag (default: reelvault/server:<serverV>-web<webV>)
#   --server-archive <file> Use a local server archive instead of downloading
#   --web-zip <file>        Use a local web zip instead of downloading
#   --skip-checksums        Skip SHA256 verification (for unpublished local files)
#   --context <dir>         Keep the assembled build context in <dir> (default: a temp dir)
#   -h, --help              Show this help
set -euo pipefail

SERVER_REPO="ReelVault/reelvault"
WEB_REPO="ReelVault/website"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG=""
SERVER_ARCHIVE=""
WEB_ZIP=""
SKIP_CHECKSUMS="false"
CONTEXT_DIR=""

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
		--tag)
			[ $# -ge 2 ] || die "--tag needs a value"
			TAG="$2"
			shift 2
			;;
		--server-archive)
			[ $# -ge 2 ] || die "--server-archive needs a value"
			SERVER_ARCHIVE="$2"
			shift 2
			;;
		--web-zip)
			[ $# -ge 2 ] || die "--web-zip needs a value"
			WEB_ZIP="$2"
			shift 2
			;;
		--skip-checksums) SKIP_CHECKSUMS="true"; shift ;;
		--context)
			[ $# -ge 2 ] || die "--context needs a value"
			CONTEXT_DIR="$2"
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

[ -n "$SERVER_VERSION" ] && [ -n "$WEB_VERSION" ] || { usage; die "need both versions: ./scripts/build-docker.sh <server-version> <web-version>"; }

SERVER_VERSION="${SERVER_VERSION#v}"
WEB_VERSION="${WEB_VERSION#v}"
command -v docker >/dev/null || die "the docker CLI is required"
command -v unzip >/dev/null || die "unzip is required"
command -v sha256sum >/dev/null || command -v shasum >/dev/null || die "sha256sum (or shasum) is required"

SERVER_TAG="v${SERVER_VERSION}"
WEB_TAG="v${WEB_VERSION}"
SERVER_ASSET="ReelVault-Server-${SERVER_VERSION}-linux-x64.tar.gz"
WEB_ASSET="reelvault-web-${WEB_VERSION}.zip"
[ -n "$TAG" ] || TAG="reelvault/server:${SERVER_VERSION}-web${WEB_VERSION}"

fetch() { curl -fsSL -o "$2" "$1"; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

verify_checksum() { # <repo> <tag> <asset> <file>
	[ "$SKIP_CHECKSUMS" = "true" ] && return 0
	local sums="$WORK/sums-$3"
	fetch "https://github.com/$1/releases/download/$2/SHA256SUMS.txt" "$sums"
	local expected
	expected="$(grep -E "^[0-9a-fA-F]{64}[[:space:]]+\*?(\./)?$3\$" "$sums" | cut -d' ' -f1 | head -1)"
	[ -n "$expected" ] || die "SHA256SUMS.txt of $1 $2 has no entry for $3"
	local actual
	actual="$(sha256_of "$4")"
	[ "$actual" = "$expected" ] || die "$3 failed the SHA256 check (expected $expected, got $actual)"
	echo "    verified: $3"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reelvault-docker.XXXXXX")"
[ -n "$CONTEXT_DIR" ] || CONTEXT_DIR="$WORK/context"
trap 'rm -rf "$WORK"' EXIT

echo "==> Building ${TAG}"
mkdir -p "$CONTEXT_DIR"

SERVER_FILE="$WORK/server.tar.gz"
if [ -n "$SERVER_ARCHIVE" ]; then
	[ -f "$SERVER_ARCHIVE" ] || die "server archive not found: $SERVER_ARCHIVE"
	cp "$SERVER_ARCHIVE" "$SERVER_FILE"
else
	echo "==> Downloading server ${SERVER_TAG}"
	fetch "https://github.com/${SERVER_REPO}/releases/download/${SERVER_TAG}/${SERVER_ASSET}" "$SERVER_FILE"
	verify_checksum "$SERVER_REPO" "$SERVER_TAG" "$SERVER_ASSET" "$SERVER_FILE"
fi

WEB_FILE="$WORK/web.zip"
if [ -n "$WEB_ZIP" ]; then
	[ -f "$WEB_ZIP" ] || die "web release not found: $WEB_ZIP"
	cp "$WEB_ZIP" "$WEB_FILE"
else
	echo "==> Downloading web UI ${WEB_TAG}"
	fetch "https://github.com/${WEB_REPO}/releases/download/${WEB_TAG}/${WEB_ASSET}" "$WEB_FILE"
	verify_checksum "$WEB_REPO" "$WEB_TAG" "$WEB_ASSET" "$WEB_FILE"
fi

echo "==> Assembling the build context"
tar -xzf "$SERVER_FILE" -C "$CONTEXT_DIR"
[ -d "$CONTEXT_DIR/ReelVault/server" ] || die "the server archive has an unexpected layout (no ReelVault/server)"
unzip -q "$WEB_FILE" -d "$CONTEXT_DIR/ReelVault/web"
[ -f "$CONTEXT_DIR/ReelVault/web/index.html" ] || die "the web release has an unexpected layout (no index.html at its root)"
cp "$REPO_ROOT/Dockerfile" "$CONTEXT_DIR/"

echo "==> docker build"
docker build -t "$TAG" "$CONTEXT_DIR"

echo
echo "Done. Image built: ${TAG}"
echo "Push it to your registry, e.g.: docker push ${TAG}"
