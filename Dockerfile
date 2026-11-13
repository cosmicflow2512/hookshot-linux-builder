# hookshot-linux-builder: baut NotRexed/Hookshot (Linux-Spielordner) aus der eigenen .nup, ohne Fenster.
# Compiler, Python, Sysroot, FFmpeg und SDL2 bringt die offizielle AppImage mit (zur Laufzeit nach /config geladen).
# Das Image braucht nur, was deren Werkzeuge vom System laden (clang: libz, libstdc++), plus Web-UI und Deploy.
FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl python3 zlib1g libstdc++6 file rsync openssh-client \
    && rm -rf /var/lib/apt/lists/*

ENV CONFIG_DIR=/config \
    NUP_DIR=/nup \
    OUT_DIR=/output \
    WEBUI_PORT=8485 \
    PYTHONUNBUFFERED=1

ARG GIT_SHA=unbekannt
ENV IMAGE_REV=${GIT_SHA}
COPY scripts/ /app/scripts/
COPY webui/ /app/webui/
RUN chmod +x /app/scripts/*.sh

EXPOSE 8485
VOLUME ["/config"]
ENTRYPOINT ["/app/scripts/entrypoint.sh"]
