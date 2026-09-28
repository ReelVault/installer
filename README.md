# ReelVault Installer

Distribution and packaging for ReelVault: the platform installers, the optional
bundle assembler, and the Docker image. The server code lives in
[ReelVault/reelvault](https://github.com/ReelVault/reelvault), the web client in
[ReelVault/website](https://github.com/ReelVault/website).

## Release model

| Repository | Artifact | Consumed by |
|---|---|---|
| `reelvault` | `ReelVault-Server-<v>-<platform>.tar.gz` (+ `SHA256SUMS.txt`) | server updates from the admin panel, installers |
| `website` | `reelvault-web-<v>.zip` (+ `release.json`, `SHA256SUMS.txt`) | web UI updates from the admin panel, installers |
| `installer` | optional bundles: `ReelVault-<serverV>-web<webV>-<platform>[-full]` | fresh installs from a single file |
| `installer` | `Dockerfile` (built locally) | Docker deployments |

- **The installers never need an update.** They resolve the **latest** server
  and web releases at install time, verify the published SHA256 checksums and
  compose the installation from the two component archives.
- **Server and web releases are fully independent** — the admin panel updates
  each component on its own schedule; a web release never waits for a server
  release.
- **Bundles are optional.** They pack the exact same component artifacts into
  one offline file (`--full` adds a pinned static ffmpeg/ffprobe into `bin/`).
  Component releases never ship ffmpeg — only bundles do.
- Releases are built by CI: pushing a `v*` tag (or dispatching the workflow)
  in each component repository builds and publishes its artifacts. In this
  repository, bundles are built **only** when you push a `v*` tag: the workflow
  resolves the latest server and web releases at that moment, packs both
  variants and attaches them (plus `Dockerfile`, `docker-compose.yml` and the
  nginx config) to that release. Nothing here needs manual updating.

## Automated release flow

```bash
# 1. Server — push a tag matching package.json (or use Actions → Release server):
git tag v1.0.1 && git push origin v1.0.1        # CI builds + publishes the release

# 2. Web — push a tag matching package.json:
git tag v0.2.0 && git push origin v0.2.0        # CI builds + publishes the release

# 3. Bundle (automatic on schedule, or run locally):
./scripts/assemble.sh 1.0.1 0.2.0 --full        # dist/bundles/* + SHA256SUMS.txt
```

Manual runs: **Actions → Release server / Release web → Run workflow** (with an
optional version; CI verifies the tag matches `package.json` before publishing).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ReelVault/installer/main/install/install.sh | bash
```

Options: `--remote`, `--port 8080`, `--dir /srv/reelvault`, `--version vX.Y.Z`
(server), `--web-version vA.B.C` (web), `--full` (force a static ffmpeg pair
into `bin/`), `--server-file` / `--web-file` (install from local artifacts),
`--no-service`, `--uninstall [--purge]`. Windows: `install.ps1`
(`-Remote -Port 8080 -Autostart -Full -Version … -WebVersion …`).

By default the installers pick the latest release of each component. Pinned or
offline installs can point them at local files.

## Docker

The image runs exactly the released artifacts — no source builds:

```bash
./scripts/build-docker.sh 1.0.1 0.2.0 --tag reelvault/server:local
# or manually:
curl -fsSLO https://github.com/ReelVault/reelvault/releases/download/v1.0.1/ReelVault-Server-1.0.1-linux-x64.tar.gz
curl -fsSLO https://github.com/ReelVault/website/releases/download/v0.2.0/reelvault-web-0.2.0.zip
tar -xzf ReelVault-Server-1.0.1-linux-x64.tar.gz && unzip reelvault-web-0.2.0.zip -d ReelVault/web
docker build -t reelvault/server:local .
```

`docker-compose.yml` and `nginx/` cover single-host deployments and reverse
proxying. Push the built image to any registry of your choice.
