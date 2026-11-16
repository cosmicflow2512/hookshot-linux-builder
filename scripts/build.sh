#!/usr/bin/env bash
# hookshot-linux-builder: baut den Linux-Spielordner von Hookshot/Hookshot oder MagicBeanDev/Longshot mit der offiziellen
# Builder-AppImage des Projekts, ohne Fenster. Welches Projekt: Auswahl der Web-UI ($CONFIG_DIR/project), sonst PROJECT.
#
#   build.sh check    neuestes Release gegen den geladenen Builder und den gebauten Spielordner
#   build.sh update   AppImage des gewaehlten Releases (Standard: neuestes stabiles) laden, Pruefsumme pruefen, entpacken
#   build.sh build    AppRun --cli (nx2/make_game.py): .nup lesen, Lift, Kompilieren, Spielordner nach $OUT_DIR
#   build.sh deploy   Spielordner per rsync/SSH auf den Linux-Rechner (DEPLOY_TARGET)
#   build.sh all      update + build (+ deploy bei AUTO_DEPLOY=true)
#
# Die AppImage wird entpackt statt gemountet (in Docker gibt es kein FUSE). Ihr AppRun setzt Compiler, Sysroot, FFmpeg
# und SDL2 selbst (Longshot laedt sie beim ersten --cli nach $XDG_DATA_HOME/longshot/builder/toolchains); "--cli" ist laut
# Upstream-README nx2/make_game.py mit dessen Optionen.
set -euo pipefail

CONFIG_DIR=${CONFIG_DIR:-/config}
NUP_DIR=${NUP_DIR:-/nup}
PROJECT=${PROJECT:-hookshot}
if [[ -s $CONFIG_DIR/project ]]; then PROJECT=$(tr -d ' \r\n' < "$CONFIG_DIR/project"); fi
# Je Projekt: Quelle, Namen im Spielordner (bin/<p>, <p>_env.txt, <p>_version.txt), Prefix der Upstream-Variablen und wo
# sein Zustand liegt. Hookshot behaelt die bisherigen Pfade direkt unter $CONFIG_DIR.
case $PROJECT in
    hookshot)
        NAME=Hookshot P=hookshot UP=HOOKSHOT
        REPO=${HOOKSHOT_REPO:-Hookshot/Hookshot}
        HOST=${HOOKSHOT_HOST:-https://git.notrexed.dev}
        STATE=$CONFIG_DIR
        OUT_DIR=${OUT_DIR:-/output}
        REF=${HOOKSHOT_REF:-latest}
        DEPLOY_TARGET=${DEPLOY_TARGET:-}
        SIGN_KEY=
        ;;
    longshot)
        NAME=Longshot P=longshot UP=LONGSHOT
        REPO=${LONGSHOT_REPO:-MagicBeanDev/Longshot}
        HOST=${LONGSHOT_HOST:-https://git.magicbean.dev}
        STATE=$CONFIG_DIR/longshot
        OUT_DIR=${LONGSHOT_OUT_DIR:-/output-longshot}
        REF=${LONGSHOT_REF:-latest}
        DEPLOY_TARGET=${LONGSHOT_DEPLOY_TARGET:-}
        # Oeffentlicher Release-Schluessel (ECDSA P-256) aus Longshots scripts/release_keys.json: SHA256SUMS.sig ist die
        # base64-kodierte DER-Signatur von SHA256SUMS (docs/releases.md, "Signing").
        SIGN_KEY=${LONGSHOT_RELEASE_KEY:-MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE5PKAyo4V9MLugswS3bMuUstnNAeNqaQBHbrDfpyhHu58osA/N8hEFI7WXqMwFh1oUFYfLaCe+AkTQ5IlTWirCQ==}
        ;;
    *) printf '\nFEHLER: PROJECT=%s unbekannt (hookshot|longshot)\n' "$PROJECT" >&2; exit 1 ;;
esac
GH="${HOST%/}/$REPO"
API="${HOST%/}/api/v1/repos/$REPO"
# Welches Release: die Auswahl aus der Web-UI ($STATE/ref), sonst <PROJEKT>_REF. latest = neuestes stabiles Release (gibt es
# keines, die neueste Vorabversion), sonst der Tag eines Releases: v2.1.0, v3.0.0-rc.5, nightly, nightly-348-689a4345 ...
if [[ -s $STATE/ref ]]; then REF=$(tr -d ' \r\n' < "$STATE/ref"); fi
LANGUAGE=${LANGUAGE:-de}
BUILDERS="$STATE/builder"
WORK="$STATE/work"
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
# Limit bekommen sie deshalb feste Werte: <P>_MEM_LIMIT_GB = Limit minus 2 GB, und beim Lift ein Worker unter
# 10 GB, darueber je 2 GB nach 4 GB fuer den Hauptprozess. Ohne Limit entscheidet Upstream selbst. Longshot liest dieselben
# Variablen mit LONGSHOT_ statt HOOKSHOT_; gesetzt werden duerfen beide Namen.
MEM_LIMIT_GB=${LONGSHOT_MEM_LIMIT_GB:-${HOOKSHOT_MEM_LIMIT_GB:-}}
LIFT_JOBS=${LONGSHOT_LIFT_JOBS:-${HOOKSHOT_LIFT_JOBS:-}}
if [[ -n $(cgroup_limit_mb) ]]; then
    b=$(budget_mb)
    if [[ -z $MEM_LIMIT_GB ]]; then
        MEM_LIMIT_GB=$(( (b - 2048) / 1024 )); (( MEM_LIMIT_GB >= 2 )) || MEM_LIMIT_GB=2
    fi
    if [[ -z $LIFT_JOBS ]]; then
        if (( b < 10240 )); then LIFT_JOBS=1; else LIFT_JOBS=$(( (b - 4096) / 2048 )); fi
    fi
fi
[[ -n $MEM_LIMIT_GB ]] && export "${UP}_MEM_LIMIT_GB=$MEM_LIMIT_GB"
[[ -n $LIFT_JOBS ]] && export "${UP}_LIFT_JOBS=$LIFT_JOBS"
[[ -n ${JOBS:-} ]] && export "${UP}_JOBS=$JOBS"

# mawk (Ubuntus awk) liest eine Pipe blockweise: die Zeilen des Builds kaemen erst nach 4 KB im Log an. -W interactive
# liest zeilenweise.
AWK=(awk)
if awk -W version 2>&1 | grep -qi mawk; then AWK=(awk -W interactive); fi

valid_tag() { [[ $1 =~ ^[A-Za-z0-9._+-]{1,80}$ ]]; }

# Forgejo liefert das neueste stabile Release direkt ueber die API. Ohne stabiles Release (Longshot vor v3.0.0) antwortet
# /releases/latest mit 404: dann das neueste Release mit v-Tag aus der Liste, auch eine Vorabversion.
latest_tag() {
    local tag
    if ! tag=$({ "${CURL[@]}" "$API/releases/latest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'; } 2>/dev/null); then
        tag=$("${CURL[@]}" "$API/releases?limit=50" | python3 -c '
import json,re,sys
rels=[r for r in json.load(sys.stdin) if not r.get("draft") and re.match(r"^v\d", r.get("tag_name") or "")]
print(next(r["tag_name"] for r in rels))
') || return 1
        echo "  (kein stabiles Release von $REPO: latest nimmt die neueste Vorabversion $tag)" >&2
    fi
    valid_tag "$tag" || return 1
    echo "$tag"
}

want_tag() {
    if [[ $REF == latest ]]; then
        latest_tag || die "neuestes Release von $REPO nicht ermittelbar (Netz? ${UP}_REF auf ein Tag setzen)"
    else
        valid_tag "$REF" || die "${UP}_REF=$REF ist kein gueltiges Tag"
        echo "$REF"
    fi
}

# SHA256SUMS eines Releases, dessen Signatur SHA256SUMS.sig mit SIGN_KEY geprueft ist (Longshot). Ohne gueltige Signatur
# nichts: wie der Longshot Launcher, der ein Release ohne gueltige Signatur ablehnt.
signed_sums() {
    local d rc=0
    d=$(mktemp -d)
    {
        "${CURL[@]}" -o "$d/SHA256SUMS" "$GH/releases/download/$1/SHA256SUMS" &&
        "${CURL[@]}" -o "$d/sig.b64" "$GH/releases/download/$1/SHA256SUMS.sig"
    } 2>/dev/null || { echo "  SHA256SUMS oder SHA256SUMS.sig von $1 nicht ladbar" >&2; rc=1; }
    if (( rc == 0 )); then
        printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$SIGN_KEY" > "$d/key.pem"
        if base64 -d "$d/sig.b64" > "$d/sig.der" 2>/dev/null &&
           openssl dgst -sha256 -verify "$d/key.pem" -signature "$d/sig.der" "$d/SHA256SUMS" >/dev/null 2>&1; then
            echo "  Signatur von SHA256SUMS stimmt (Release-Schluessel von $NAME)" >&2
            cat "$d/SHA256SUMS"
        else
            echo "  Signatur von SHA256SUMS ($1) ungueltig" >&2; rc=1
        fi
    fi
    rm -rf "$d"
    return $rc
}

# Name und Pruefsumme der Linux-AppImage eines Releases ("<hash> <name>"). Mit SIGN_KEY nur aus der signierten SHA256SUMS.
# Sonst (Hookshot) SHA256SUMS aelterer Releases bevorzugen; neue Releases liefern die Pruefsumme im zsync-Header, der
# AppImage-Name kommt aus den Release-Assets.
release_appimage() {
    local sums name hash
    if [[ -n $SIGN_KEY ]]; then
        sums=$(signed_sums "$1") || return 1
        awk -v re="^$NAME-.*-x86_64\\.AppImage$" '$2 ~ re && $1 ~ /^[0-9a-f]{64}$/ {print $1, $2; exit}' <<<"$sums" | grep . && return 0
        echo "  keine $NAME-...-x86_64.AppImage in SHA256SUMS von $1" >&2
        return 1
    fi
    if sums=$("${CURL[@]}" "$GH/releases/download/$1/SHA256SUMS" 2>/dev/null); then
        awk -v re="^$NAME-.*-x86_64\\.AppImage$" '$2 ~ re {print $1, $2; exit}' <<<"$sums" | grep . && return 0
    fi
    name=$("${CURL[@]}" "$API/releases/tags/$1" | NAME=$NAME python3 -c '
import json,os,re,sys
assets=json.load(sys.stdin).get("assets", [])
print(next(a["name"] for a in assets if re.fullmatch(re.escape(os.environ["NAME"]) + r"-.*-x86_64\.AppImage", a["name"])))
') || return 1
    hash=$("${CURL[@]}" "$GH/releases/download/$1/$name.zsync" | python3 -c '
import re,sys
header=sys.stdin.buffer.read().split(b"\n\n", 1)[0]
m=re.search(rb"(?m)^SHA-1: ([0-9a-fA-F]{40})\r?$", header)
if not m: sys.exit(1)
print(m.group(1).decode().lower())
') || return 1
    echo "$hash $name"
}

appimage_version() { local v=${1#"$NAME"-}; echo "${v%-x86_64.AppImage}"; }

builder_tag() { [[ -f $BUILDERS/current ]] && tr -d ' \r\n' < "$BUILDERS/current" || true; }
apprun() {
    local tag; tag=$(builder_tag)
    [[ -n $tag && -x $BUILDERS/$tag/AppRun ]] && echo "$BUILDERS/$tag/AppRun"
}
game_tag() { { sed -n 's/^version=//p' "$OUT_DIR/${P}_version.txt" 2>/dev/null || true; } | head -1 | tr -d '\r '; }

stage_update() {
    local tag name tmp want ver line checksum
    tag=$(want_tag)
    log "Builder fuer $tag ($GH/releases/tag/$tag)"
    mkdir -p "$BUILDERS"
    line=$(release_appimage "$tag") ||
        die "Pruefsumme von $tag nicht ladbar, Signatur ungueltig oder ohne Linux-AppImage: nichts wird ungeprueft entpackt"
    want=${line%% *} name=${line#* }
    ver=$(appimage_version "$name")
    valid_tag "$ver" || die "unerwarteter AppImage-Name: $name"
    if [[ -x $BUILDERS/$ver/AppRun ]]; then
        echo "  schon entpackt: $BUILDERS/$ver"
    else
        tmp="$BUILDERS/.dl"
        rm -rf "$tmp"; mkdir -p "$tmp"
        echo "  lade $name"
        "${CURL[@]}" -o "$tmp/$name" "$GH/releases/download/$tag/$name" || die "Download von $name fehlgeschlagen"
        case ${#want} in
            64) checksum=$(sha256sum "$tmp/$name" | cut -d' ' -f1) ;;
            40) checksum=$(sha1sum "$tmp/$name" | cut -d' ' -f1) ;;
            *) die "ungueltige Pruefsumme fuer $name" ;;
        esac
        [[ $checksum == "$want" ]] || die "Pruefsumme von $name stimmt nicht"
        echo "  Pruefsumme stimmt ($want)"
        chmod +x "$tmp/$name"
        (cd "$tmp" && "./$name" --appimage-extract >/dev/null) || die "Entpacken der AppImage fehlgeschlagen"
        [[ -x $tmp/squashfs-root/AppRun ]] || die "AppRun fehlt in der AppImage"
        mv "$tmp/squashfs-root" "$BUILDERS/$ver"
        rm -rf "$tmp"
    fi
    echo "$ver" > "$BUILDERS/current"
    local d
    for d in "$BUILDERS"/*/; do   # andere Builder dieses Projekts (je einige 100 MB) weg
        d=${d%/}
        if [[ -d $d && $(basename "$d") != "$ver" ]]; then rm -rf "$d"; fi
    done
    echo "  Builder: $ver  ($(du -sh "$BUILDERS/$ver" | cut -f1))"
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
# Prozent, die Zeile je kompilierter Datei entfaellt. Fortschritt, den Upstream mit \r in dieselbe Zeile schreibt (Longshots
# Download der Build-Werkzeuge: "Downloading the build tools (1 of 5, emsdk, 134 MB)  43%"), kaeme ohne Zeilenende nie im
# Log an: \r trennt hier wie \n, und solche Zeilen erscheinen je Schritt in 10-%-Stufen. Python statt awk, weil mawk
# zeilenweise (-W interactive) nur an \n trennt.
readable() {
    python3 -u -I -c '
import os, re, sys
PCT = re.compile(r"^(.*?)\s+(\d{1,3})\s*%\s*$")
last_pct, step = -1, None
def out(s):
    sys.stdout.write(s + "\n"); sys.stdout.flush()
def line(l):
    global last_pct, step
    if not l.strip():
        return
    if l.startswith("@@progress "):
        try:
            p = int(float(l.split()[1]) * 100)
        except (IndexError, ValueError):
            return
        if p != last_pct:
            last_pct = p; out("    %3d %%" % p)
        return
    if l.startswith("@@file "):
        return
    if l.startswith("@@stage "):
        out("\n--- " + l.split(" ", 2)[2] if l.count(" ") >= 2 else l[2:]); last_pct = -1; return
    if l.startswith("@@"):
        out(l[2:]); return
    m = PCT.match(l)
    if m:
        p = int(m.group(2)) // 10 * 10
        if (m.group(1), p) != step:
            step = (m.group(1), p); out("%s  %d%%" % (m.group(1), int(m.group(2))))
        return
    step = None
    out(l)
buf = b""
while True:
    chunk = os.read(0, 65536)
    if not chunk:
        break
    buf += chunk
    parts = re.split(rb"\r\n|\r|\n", buf)
    buf = parts.pop()
    for part in parts:
        line(part.decode("utf-8", "replace"))
if buf:
    line(buf.decode("utf-8", "replace"))
'
}

stage_build() {
    local run nup args
    run=$(apprun) || true
    if [[ -z $run ]]; then stage_update; run=$(apprun); fi
    out_mounted
    mkdir -p "$OUT_DIR" "$WORK"
    nup=$(find_nup)
    args=(--work "$WORK" --no-prepare-shaders)
    if [[ -n $nup ]]; then
        args+=(--nup "$nup" --out "$OUT_DIR" --language "$LANGUAGE")
        log "Build $(builder_tag) aus $(basename "$nup") nach $OUT_DIR"
    elif [[ -d $OUT_DIR/.${P}_exefs && -d $OUT_DIR/romfs ]]; then
        args+=(--update "$OUT_DIR")
        log "Build $(builder_tag): Update von $OUT_DIR aus den Spieldateien, die der Ordner behalten hat (keine .nup unter $NUP_DIR)"
    else
        die "keine .nup unter $NUP_DIR gefunden (NUP_FILE setzen) und $OUT_DIR ist kein frueher gebauter Spielordner"
    fi
    # shellcheck disable=SC2206
    [[ -n ${EXTRA_ARGS:-} ]] && args+=($EXTRA_ARGS)
    # Die Shader bereitet das Spiel beim ersten Start auf dem Zielrechner vor: hier gibt es keine Grafikkarte, und
    # vorbereitet wuerde ohnehin fuer die GPU dieses Rechners.
    env "${UP}_NO_PREPARE=1" "$run" --cli "${args[@]}" 2>&1 | readable
    [[ -x $OUT_DIR/bin/$P && -f $OUT_DIR/image.bin ]] || die "bin/$P oder image.bin fehlt nach dem Build in $OUT_DIR"

    # Das Update-Angebot des Spiels (Hookshot: host/hos_update.c) wuerde den Builder starten, der den Ordner gebaut hat.
    # Der liegt im Container, nicht auf dem Zielrechner: aus, Updates baut dieser Container.
    local envf="$OUT_DIR/${P}_env.txt"
    if ! grep -qs "^${UP}_NO_UPDATE_CHECK=" "$envf"; then
        printf '%s_NO_UPDATE_CHECK=1\n' "$UP" >> "$envf"
    fi
    printf '{"project": "%s", "tag": "%s", "time": "%s", "nup": "%s"}\n' "$P" "$(game_tag)" "$(date '+%d.%m.%Y %H:%M')" \
        "$(basename "${nup:-}")" > "$STATE/build-info.json"
    if [[ -n ${PUID:-} && -n ${PGID:-} ]]; then
        chown -R "$PUID:$PGID" "$OUT_DIR" 2>/dev/null || echo "  Hinweis: Besitzer von $OUT_DIR nicht auf $PUID:$PGID gesetzt"
    fi
    log "Fertig: $OUT_DIR  ($NAME $(game_tag), $(du -sh "$OUT_DIR" | cut -f1)). Start auf dem Zielrechner: ./$P"
}

stage_deploy() {
    [[ -x $OUT_DIR/bin/$P ]] || die "kein $NAME-Build vorhanden (erst build)"
    local dv=DEPLOY_TARGET; [[ $P == longshot ]] && dv=LONGSHOT_DEPLOY_TARGET
    [[ -n $DEPLOY_TARGET ]] || die "$dv ist leer (Form: benutzer@rechner:/pfad/zum/Spielordner)"
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
    local latest have built tag line want update=false
    latest=$(latest_tag) || die "neuestes Release von $REPO nicht ermittelbar"
    tag=$(want_tag)
    line=$(release_appimage "$tag") || die "Pruefsumme von $tag nicht ladbar, Signatur ungueltig oder ohne Linux-AppImage"
    want=$(appimage_version "${line#* }")
    have=$(builder_tag); built=$(game_tag)
    printf '  %-28s %s\n' "Projekt:" "$NAME ($REPO)" "Neuestes Release (latest):" "$latest" "Gewaehlt ($REF):" "$want" \
        "Builder im Container:" "${have:-keiner}" "Gebauter Spielordner:" "${built:-keiner}"
    [[ $built == "$want" ]] || update=true
    if [[ $update == true ]]; then echo "  -> \"Alles bauen\" bringt den Spielordner auf $want."; else echo "  -> alles aktuell."; fi
    printf '{"time": "%s", "latest": "%s", "want": "%s", "builder": "%s", "built": "%s", "update": %s}\n' \
        "$(date '+%d.%m.%Y %H:%M')" "$latest" "$want" "$have" "$built" "$update" > "$STATE/update-check.json"
}

# Der Spielordner muss auf einem eingebundenen Pfad liegen, sonst verschwindet er mit dem Container (z. B. wenn im Template
# der Pfad fuer /output-longshot fehlt).
out_mounted() {
    mkdir -p "$OUT_DIR" 2>/dev/null || true
    if [[ $(stat -c %d "$OUT_DIR" 2>/dev/null) == "$(stat -c %d / 2>/dev/null)" ]]; then
        die "$OUT_DIR liegt im Container selbst, nicht auf einem eingebundenen Pfad: im Template einen Pfad fuer $OUT_DIR anlegen"
    fi
}

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }

stage=${1:-all}
mkdir -p "$CONFIG_DIR" "$STATE" "$HOME"
IMAGE_REV=${IMAGE_REV:-unbekannt}
echo "Image: ${IMAGE_REV:0:7}  Projekt: $NAME  Ref: $REF  Sprache: $LANGUAGE  Jobs: ${JOBS:-auto}  Compiler-RAM: ${MEM_LIMIT_GB:-auto} GB  Lift: ${LIFT_JOBS:-auto}  RAM frei: $(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo) GB  Container-Limit: $(l=$(cgroup_limit_mb); if [[ -n $l ]]; then echo "$l MB"; else echo keins; fi)"
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
