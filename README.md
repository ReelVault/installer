# ReelVault Installer

Installers and a Docker setup for ReelVault. Each installer downloads the latest server and web release, checks their SHA-256 checksums and sets everything up for you.

## Install

### Windows

In PowerShell:

```powershell
irm https://raw.githubusercontent.com/ReelVault/installer/main/install/install.ps1 | iex
```

This installs ReelVault and adds a Start Menu shortcut. Open it, or go to http://localhost:3030.

To pass options, download the script first:

```powershell
irm https://raw.githubusercontent.com/ReelVault/installer/main/install/install.ps1 -OutFile install.ps1
.\install.ps1 -Remote        # reachable from other devices on your network
.\install.ps1 -Port 8080     # use another port
.\install.ps1 -Upgrade       # update and keep your data
```

Prefer a double-click? Download [`install/install.bat`](install/install.bat) and run it.

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ReelVault/installer/main/install/install.sh | bash
```

To pass options, download the script first:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/ReelVault/installer/main/install/install.sh
bash install.sh --remote     # reachable from other devices on your network
bash install.sh --port 8080  # use another port
bash install.sh --upgrade    # update and keep your data
bash install.sh --uninstall  # remove ReelVault (add --purge to delete data too)
```

### Options

| Option | Windows | Linux | What it does |
|---|---|---|---|
| Listen on the network | `-Remote` | `--remote` | Accept connections from other devices |
| Port | `-Port 8080` | `--port 8080` | HTTP port (default 3030) |
| Install folder | `-Dir` | `--dir` | Where to install |
| Server version | `-Version` | `--version` | Pin a server release (default: latest) |
| Web app version | `-WebVersion` | `--web-version` | Pin a web app release (default: latest) |
| Bundle ffmpeg | `-Full` | `--full` | Include a static ffmpeg and ffprobe |
| Offline server file | `-ServerFile` | `--server-file` | Install from a downloaded server archive |
| Offline web file | `-WebFile` | `--web-file` | Install from a downloaded web archive |
| Start with the system | `-Autostart` | | Start ReelVault when you sign in |
| Skip the service | | `--no-service` | Do not register a background service |
| Update | `-Upgrade` | `--upgrade` | Replace the app and keep your data |
| Remove | `-Uninstall` (`-Purge`) | `--uninstall` (`--purge`) | Remove ReelVault, and optionally its data |

## Docker

```bash
mkdir reelvault && cd reelvault
curl -fsSLO https://raw.githubusercontent.com/ReelVault/installer/main/docker-compose.yml
docker compose up -d
```

Open http://localhost:3030 and create the administrator account. Your data lives in the `reelvault-data` volume.

To scan your media, mount the folder in `docker-compose.yml`. Uncomment the media line and point it at your folder:

```yaml
    volumes:
      - reelvault-data:/data
      - /srv/media:/media:ro
```

To serve the web app with nginx instead of the built-in one, use the `web` profile. It expects a built website at `../website/dist`:

```bash
docker compose --profile web up -d
```

## Offline installs

Download the release archives yourself, then point the installer at them with `--server-file` and `--web-file` (or `-ServerFile` and `-WebFile`). The installer then skips the download.

## For maintainers

### Release model

| Repository | Artifact | Used by |
|---|---|---|
| `reelvault` | `ReelVault-Server-<version>-<platform>.tar.gz` (or `.zip` on Windows), with `SHA256SUMS.txt` | Server updates from the admin panel, installers |
| `website` | `reelvault-web-<version>.zip`, with `release.json` and `SHA256SUMS.txt` | Web updates from the admin panel, installers |
| `installer` | Bundles: `ReelVault-<serverVersion>-web<webVersion>-<platform>[-full]` | Fresh installs from one file |
| `installer` | Image `ghcr.io/reelvault/server:<serverVersion>-web<webVersion>` and `:latest` | Docker deployments |

- The installers never need an update. They always resolve the **latest** server and web release at install time.
- Server and web releases are independent. The admin panel updates each one on its own schedule.
- Bundles are optional. They pack the same component archives into one offline file. `--full` (`-Full`) also adds a pinned static ffmpeg and ffprobe. Component releases never include ffmpeg; only bundles do.
- Pushing a `v*` tag in a component repository builds and publishes its release. In this repository, pushing a `v*` tag builds the bundles and attaches them to the release, together with `Dockerfile`, `docker-compose.yml` and the nginx config.
- The same tag also runs **Docker image**, which builds the server image from the latest releases and pushes it to GitHub Container Registry. The first push creates a private package. Make it public under the package settings, or `docker compose up` cannot pull it.

```bash
# Server release: push a tag that matches package.json
git tag v1.3.0 && git push origin v1.3.0

# Web release: push a tag that matches package.json
git tag v1.3.0 && git push origin v1.3.0

# Bundle, locally
./scripts/assemble.sh 1.3.0 1.3.0 --full     # writes dist/bundles/ and SHA256SUMS.txt
```

You can also run **Actions → Release server** or **Release web** by hand, with an optional version. CI checks that the tag matches `package.json` before it publishes.

### Build the Docker image locally

The image runs the released artifacts, not a source build. To build your own copy instead of pulling the published one:

```bash
./scripts/build-docker.sh 1.3.0 1.3.0 --tag reelvault/server:local
```
