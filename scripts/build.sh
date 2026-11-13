#!/usr/bin/env bash
# hookshot-linux-builder: baut den Linux-Spielordner von NotRexed/Hookshot mit dessen offizieller AppImage, ohne Fenster.
#
#   build.sh check    neuestes Release gegen den geladenen Builder und den gebauten Spielordner
#   build.sh update   AppImage von HOOKSHOT_REF (Standard: neuestes Release) laden, pruefen (SHA256SUMS), entpacken
#   build.sh build    AppRun --cli (nx2/make_game.py): .nup lesen, Lift, Kompilieren, Spielordner nach $OUT_DIR
#   build.sh deploy   Spielordner per rsync/SSH auf den Linux-Rechner (DEPLOY_TARGET)
#   build.sh all      update + build (+ deploy bei AUTO_DEPLOY=true)
#
# Die AppImage wird entpackt statt gemountet (in Docker gibt es kein FUSE). Ihr AppRun setzt Compiler, Sysroot, FFmpeg
# und SDL2 selbst; "--cli" ist laut Upstream-README nx2/make_game.py mit dessen Optionen.
set -euo pipefail

CONFIG_DIR=${CONFIG_DIR:-/config}
NUP_DIR=${NUP_DIR:-/nup}
OUT_DIR=${OUT_DIR:-/output}
REPO=${HOOKSHOT_REPO:-NotRexed/Hookshot}
GH="https://github.com/$REPO"
REF=${HOOKSHOT_REF:-latest}
LANGUAGE=${LANGUAGE:-de}
BUILDERS="$CONFIG_DIR/builder"
WORK="$CONFIG_DIR/work"
CURL=(curl -fsSL --retry 5 --retry-delay 10 --proto '=https')

# make_game.py und der Lift legen Cache und Einstellungen unter $HOME ab: nach /config, nicht in den Container.
export HOME="$CONFIG_DIR/home" XDG_CACHE_HOME="$CONFIG_DIR/home/.cache" XDG_CONFIG_HOME="$CONFIG_DIR/home/.config" \
       XDG_DATA_HOME="$CONFIG_DIR/home/.local/share"

log() { printf '\n==> [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '\nFEHLER: %s\n' "$*" >&2; exit 1; }

# Speicherbudget in MB: das kleinere von freiem RAM und Speicherlimit des Containers.
cgroup_limit_mb() {
    local limit
    limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
    if [[ $limit =~ ^[0-9]+$ ]]; then echo $(( limit / 1024 / 1024 )); fi
}
budget_mb() {
    local avail limit
    avail=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo 0)
    limit=$(cgroup_limit_mb)
    if [[ -n $limit ]] && (( avail == 0 || limit < avail )); then avail=$limit; fi
    echo "$avail"
}
# Upstream teilt die Compiler nach dem freien RAM des Hosts ein (nx2/build.py MemoryGate) und startet beim Lift einen
# Worker je 2 GB freiem Host-RAM (nx2/chunks.py emit_jobs). Ein Speicherlimit des Containers sehen beide nicht. Mit
# Limit bekommen sie deshalb feste Werte: HOOKSHOT_MEM_LIMIT_GB = Limit minus 2 GB, und beim Lift ein Worker unter
# 10 GB, darueber je 2 GB nach 4 GB fuer den Hauptprozess. Ohne Limit entscheidet Upstream selbst.
if [[ -n $(cgroup_limit_mb) ]]; then
    b=$(budget_mb)
    if [[ -z ${HOOKSHOT_MEM_LIMIT_GB:-} ]]; then
        HOOKSHOT_MEM_LIMIT_GB=$(( (b - 2048) / 1024 )); (( HOOKSHOT_MEM_LIMIT_GB >= 2 )) || HOOKSHOT_MEM_LIMIT_GB=2
        export HOOKSHOT_MEM_LIMIT_GB
    fi
    if [[ -z ${HOOKSHOT_LIFT_JOBS:-} ]]; then
        if (( b < 10240 )); then HOOKSHOT_LIFT_JOBS=1; else HOOKSHOT_LIFT_JOBS=$(( (b - 4096) / 2048 )); fi
        export HOOKSHOT_LIFT_JOBS
    fi
fi
[[ -n ${HOOKSHOT_MEM_LIMIT_GB:-} ]] && export HOOKSHOT_MEM_LIMIT_GB
[[ -n ${HOOKSHOT_LIFT_JOBS:-} ]] && export HOOKSHOT_LIFT_JOBS
[[ -n ${JOBS:-} ]] && export HOOKSHOT_JOBS="$JOBS"

# mawk (Ubuntus awk) liest eine Pipe blockweise: die Zeilen des Builds kaemen erst nach 4 KB im Log an. -W interactive
# liest zeilenweise.
AWK=(awk)
if awk -W version 2>&1 | grep -qi mawk; then AWK=(awk -W interactive); fi

valid_tag() { [[ $1 =~ ^[A-Za-z0-9._+-]{1,80}$ ]]; }

# Neuestes Release, aus zwei Quellen: hookshot-linux.txt des "latest"-Releases (die Liste, die Upstreams eigener
# Updater liest, builder/linux/linux_update.py) und die Weiterleitung von /releases/latest.
latest_tag() {
    local a b
    a=$("${CURL[@]}" "$GH/releases/latest/download/hookshot-linux.txt" 2>/dev/null | sed -n 's/^tag \(.*\)$/\1/p' | head -1 | tr -d '\r ') || a=
    b=$(curl -fsS --retry 3 --proto '=https' -o /dev/null -w '%{redirect_url}' "$GH/releases/latest" 2>/dev/null | sed -n 's#.*/releases/tag/##p') || b=
    if [[ -n $a && -n $b && $a != "$b" ]]; then
        echo "  Hinweis: hookshot-linux.txt nennt $a, /releases/latest leitet auf $b. Genommen wird $a." >&2
    fi
    local tag=${a:-$b}
    [[ -n $tag ]] && valid_tag "$tag" || return 1
    echo "$tag"
}

want_tag() {
    if [[ $REF == latest ]]; then
        latest_tag || die "neuestes Release von $REPO nicht ermittelbar (Netz? HOOKSHOT_REF auf ein Tag setzen)"
    else
        valid_tag "$REF" || die "HOOKSHOT_REF=$REF ist kein gueltiges Tag"
        echo "$REF"
    fi
}

builder_tag() { [[ -f $BUILDERS/current ]] && tr -d ' \r\n' < "$BUILDERS/current" || true; }
apprun() {
    local tag; tag=$(builder_tag)
    [[ -n $tag && -x $BUILDERS/$tag/AppRun ]] && echo "$BUILDERS/$tag/AppRun"
}
game_tag() { { sed -n 's/^version=//p' "$OUT_DIR/hookshot_version.txt" 2>/dev/null || true; } | head -1 | tr -d '\r '; }

stage_update() {
    local tag name tmp want
    tag=$(want_tag)
    log "Builder $tag ($GH/releases/tag/$tag)"
    mkdir -p "$BUILDERS"
    if [[ -x $BUILDERS/$tag/AppRun ]]; then
        echo "  schon entpackt: $BUILDERS/$tag"
    else
        name="Hookshot-$tag-x86_64.AppImage"
        tmp="$BUILDERS/.dl"
        rm -rf "$tmp"; mkdir -p "$tmp"
        echo "  lade $name"
        "${CURL[@]}" -o "$tmp/$name" "$GH/releases/download/$tag/$name" || die "Download von $name fehlgeschlagen"
        "${CURL[@]}" -o "$tmp/SHA256SUMS" "$GH/releases/download/$tag/SHA256SUMS" ||
            die "SHA256SUMS von $tag nicht ladbar: die AppImage wird nicht ungeprueft entpackt"
        want=$(awk -v n="$name" '$2 == n {print $1}' "$tmp/SHA256SUMS")
        [[ -n $want ]] || die "$name steht nicht in SHA256SUMS"
        [[ $(sha256sum "$tmp/$name" | cut -d' ' -f1) == "$want" ]] || die "SHA-256 von $name stimmt nicht"
        echo "  SHA-256 stimmt ($want)"
        chmod +x "$tmp/$name"
        (cd "$tmp" && "./$name" --appimage-extract >/dev/null) || die "Entpacken der AppImage fehlgeschlagen"
        [[ -x $tmp/squashfs-root/AppRun ]] || die "AppRun fehlt in der AppImage"
        mv "$tmp/squashfs-root" "$BUILDERS/$tag"
        rm -rf "$tmp"
    fi
    echo "$tag" > "$BUILDERS/current"
    local d
    for d in "$BUILDERS"/*/; do   # aeltere Builder (je rund 900 MB) weg
        d=${d%/}
        if [[ -d $d && $(basename "$d") != "$tag" ]]; then rm -rf "$d"; fi
    done
    echo "  Builder: $tag  ($(du -sh "$BUILDERS/$tag" | cut -f1))"
}

find_nup() {
    if [[ -n ${NUP_FILE:-} ]]; then
        [[ -f $NUP_FILE ]] || die "NUP_FILE=$NUP_FILE existiert nicht"
        echo "$NUP_FILE"; return
    fi
    local found
    found=$(find "$NUP_DIR" -maxdepth 2 -type f -iname '*0400486024dec000*.nup' 2>/dev/null | sort | head -1)
    [[ -n $found ]] || found=$(find "$NUP_DIR" -maxdepth 2 -type f -iname '*.nup' 2>/dev/null | sort | head -1)
    echo "$found"
}

# Die @@-Zeilen von make_game.py (fuer Upstreams Builder-Fenster) lesbar machen: Fortschritt nur bei jedem vollen
# Prozent, die Zeile je kompilierter Datei entfaellt.
readable() {
    "${AWK[@]}" '
        /^@@progress / { p = int($2 * 100); if (p != last) { last = p; printf "    %3d %%\n", p; fflush() } next }
        /^@@file /     { next }
        /^@@stage /    { sub(/^@@stage [^ ]+ /, ""); printf "\n--- %s\n", $0; last = -1; fflush(); next }
        /^@@/          { sub(/^@@/, ""); print; fflush(); next }
        { print; fflush() }'
}

stage_build() {
    local run nup args
    run=$(apprun) || true
    if [[ -z $run ]]; then stage_update; run=$(apprun); fi
    mkdir -p "$OUT_DIR" "$WORK"
    nup=$(find_nup)
    args=(--work "$WORK" --no-prepare-shaders)
    if [[ -n $nup ]]; then
        args+=(--nup "$nup" --out "$OUT_DIR" --language "$LANGUAGE")
        log "Build $(builder_tag) aus $(basename "$nup") nach $OUT_DIR"
    elif [[ -d $OUT_DIR/.hookshot_exefs && -d $OUT_DIR/romfs ]]; then
        args+=(--update "$OUT_DIR")
        log "Build $(builder_tag): Update von $OUT_DIR aus den Spieldateien, die der Ordner behalten hat (keine .nup unter $NUP_DIR)"
    else
        die "keine .nup unter $NUP_DIR gefunden (NUP_FILE setzen) und $OUT_DIR ist kein frueher gebauter Spielordner"
    fi
    # shellcheck disable=SC2206
    [[ -n ${EXTRA_ARGS:-} ]] && args+=($EXTRA_ARGS)
    # Die Shader bereitet das Spiel beim ersten Start auf dem Zielrechner vor: hier gibt es keine Grafikkarte, und
    # vorbereitet wuerde ohnehin fuer die GPU dieses Rechners.
    HOOKSHOT_NO_PREPARE=1 "$run" --cli "${args[@]}" 2>&1 | readable
    [[ -x $OUT_DIR/bin/hookshot && -f $OUT_DIR/image.bin ]] || die "bin/hookshot oder image.bin fehlt nach dem Build in $OUT_DIR"

    # Das Update-Angebot des Spiels (host/hos_update.c) wuerde den Builder starten, der den Ordner gebaut hat. Der liegt
    # im Container, nicht auf dem Zielrechner: aus, Updates baut dieser Container.
    local envf="$OUT_DIR/hookshot_env.txt"
    if ! grep -qs '^HOOKSHOT_NO_UPDATE_CHECK=' "$envf"; then
        printf 'HOOKSHOT_NO_UPDATE_CHECK=1\n' >> "$envf"
    fi
    printf '{"tag": "%s", "time": "%s", "nup": "%s"}\n' "$(game_tag)" "$(date '+%d.%m.%Y %H:%M')" \
        "$(basename "${nup:-}")" > "$CONFIG_DIR/build-info.json"
    if [[ -n ${PUID:-} && -n ${PGID:-} ]]; then
        chown -R "$PUID:$PGID" "$OUT_DIR" 2>/dev/null || echo "  Hinweis: Besitzer von $OUT_DIR nicht auf $PUID:$PGID gesetzt"
    fi
    log "Fertig: $OUT_DIR  (Hookshot $(game_tag), $(du -sh "$OUT_DIR" | cut -f1)). Start auf dem Zielrechner: ./hookshot"
}

stage_deploy() {
    [[ -x $OUT_DIR/bin/hookshot ]] || die "kein Build vorhanden (erst build)"
    [[ -n ${DEPLOY_TARGET:-} ]] || die "DEPLOY_TARGET ist leer (Form: benutzer@rechner:/pfad/zum/Spielordner)"
    local key="$CONFIG_DIR/ssh/id_ed25519"
    [[ -f $key ]] || die "SSH-Schluessel $key fehlt (Container neu starten)"
    log "Deploy nach $DEPLOY_TARGET (Port ${DEPLOY_PORT:-22})"
    echo "  Schluessel, der auf dem Zielrechner in ~/.ssh/authorized_keys stehen muss:"
    echo "  $(cat "$key.pub")"
    # Ohne --delete: was das Spiel auf dem Zielrechner in seinen Ordner schreibt (Einstellungen, Caches), bleibt.
    rsync -rltp --partial --no-inc-recursive --info=progress2,stats1 --exclude=.game \
        -e "ssh -i $key -p ${DEPLOY_PORT:-22} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$CONFIG_DIR/ssh/known_hosts" \
        "$OUT_DIR/" "$DEPLOY_TARGET/" 2>&1 | tr '\r' '\n' | "${AWK[@]}" '!/%/ || ++n % 50 == 0 { print; fflush() }'
    log "Deploy fertig"
}

stage_check() {
    log "Auf Updates pruefen"
    local latest have built update=false
    latest=$(latest_tag) || die "neuestes Release von $REPO nicht ermittelbar"
    have=$(builder_tag); built=$(game_tag)
    printf '  %-22s %s\n' "Neuestes Release:" "$latest" "Builder im Container:" "${have:-keiner}" "Gebauter Spielordner:" "${built:-keiner}"
    if [[ $REF != latest ]]; then
        echo "  HOOKSHOT_REF=$REF ist fest eingestellt: gebaut wird $REF, nicht $latest."
        [[ $built == "$REF" ]] || update=true
    elif [[ $built != "$latest" ]]; then
        update=true
    fi
    if [[ $update == true ]]; then echo "  -> \"Alles bauen\" bringt den Spielordner auf den gewuenschten Stand."; else echo "  -> alles aktuell."; fi
    printf '{"time": "%s", "latest": "%s", "builder": "%s", "built": "%s", "update": %s}\n' \
        "$(date '+%d.%m.%Y %H:%M')" "$latest" "$have" "$built" "$update" > "$CONFIG_DIR/update-check.json"
}

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }

stage=${1:-all}
mkdir -p "$CONFIG_DIR" "$HOME"
IMAGE_REV=${IMAGE_REV:-unbekannt}
echo "Image: ${IMAGE_REV:0:7}  Ref: $REF  Sprache: $LANGUAGE  Jobs: ${HOOKSHOT_JOBS:-auto}  Compiler-RAM: ${HOOKSHOT_MEM_LIMIT_GB:-auto} GB  Lift: ${HOOKSHOT_LIFT_JOBS:-auto}  RAM frei: $(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo) GB  Container-Limit: $(l=$(cgroup_limit_mb); if [[ -n $l ]]; then echo "$l MB"; else echo keins; fi)"
echo "Frei: $(free_gb "$CONFIG_DIR") GB unter $CONFIG_DIR, $(free_gb "$OUT_DIR") GB unter $OUT_DIR (Upstream nennt rund 60 GB waehrend des Builds)"
case $stage in
    check) stage_check ;;
    update) stage_update ;;
    build) stage_build ;;
    deploy) stage_deploy ;;
    all)
        stage_update
        stage_build
        if [[ ${AUTO_DEPLOY:-false} == true ]]; then stage_deploy; fi
        ;;
    *) die "unbekannte Stufe: $stage (check|update|build|deploy|all)" ;;
esac
