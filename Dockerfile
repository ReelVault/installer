# syntax=docker/dockerfile:1
#
# ReelVault all-in-one image: API + web UI + ffmpeg on port 3030.
#
# Built FROM AN ASSEMBLED BUNDLE (the linux-x64 archive), not from sources —
# the image runs exactly the artifacts the admin panel ships as updates:
#
#   tar -xzf ReelVault-<serverV>-web<webV>-linux-x64.tar.gz
#   docker build -t ghcr.io/reelvault/server:<tag> <dir-with-ReelVault/>
#
# ffmpeg/ffprobe come from the distro (apt). The `bin/` pair of a -full bundle
# is not used here — APP_FFMPEG_PATH stays unset and start.sh semantics do not
# apply inside the container.

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM docker.io/oven/bun:1 AS runtime

# ffmpeg/ffprobe drive transcoding, trickplay and media analyses
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ffmpeg \
	&& rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
	APP_PORT=3030 \
	APP_HOST=0.0.0.0 \
	ROOT_DIR=/data \
	APP_WEB_DIST=/web

WORKDIR /app
COPY ReelVault/server /app
COPY ReelVault/web /web

RUN mkdir -p /data /web && chown -R bun:bun /data /app /web
USER bun

VOLUME /data
EXPOSE 3030

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD bun -e "fetch('http://127.0.0.1:'+(process.env.APP_PORT??'3030')+'/v1/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["bun", "run", "src/index.ts"]
