# hookshot-linux-builder

Unraid-Container, der [Hookshot/Hookshot](https://git.notrexed.dev/Hookshot/Hookshot) baut: *The Legend of Zelda: Ocarina of
Time* (Switch-2-Version), statisch rekompiliert, als Linux-Spielordner. Aus der eigenen `.nup`, auf dem eigenen Server,
ohne Fenster. Der fertige Ordner läuft auf einem anderen Linux-Rechner (z. B. Linux auf der PS5, Steam Deck).

Wahlweise baut er [MagicBeanDev/Longshot](https://git.magicbean.dev/MagicBeanDev/Longshot), die Fortsetzung von
Hookshot (laut dessen README sind die Haupt-Maintainer dorthin gewechselt), siehe [Longshot](#longshot).

Im Image sind weder Spieldateien noch Keys oder Builds, auch nicht Hookshot selbst. Der Container lädt zur Laufzeit die
offizielle AppImage des Releases, prüft sie gegen `Release-Prüfsummen (SHA-256 oder SHA-1 aus dem zsync-Header)` des Releases und entpackt sie nach `/config`.

## Was er macht

| Stufe | Inhalt |
| --- | --- |
| check | neuestes Release gegen den geladenen Builder und den gebauten Spielordner |
| update | AppImage des gewählten Releases laden (Standard `latest`), Prüfsumme prüfen, entpacken |
| build | `AppRun --cli` (das ist `nx2/make_game.py`): `.nup` lesen, Lift, Kompilieren, Spielordner nach `/output` |
| deploy | `/output` per rsync über SSH nach `DEPLOY_TARGET`, ohne `--delete` |

Grundlage ist der Abschnitt „Linux, the AppImage from the command line" im
[Upstream-README](https://git.notrexed.dev/Hookshot/Hookshot/src/branch/main/readme.md#build-from-source). Die AppImage bringt
Compiler (clang/lld), Python, ein glibc-2.35-Sysroot, FFmpeg und SDL2 mit. Sie wird entpackt statt gemountet, weil es
in Docker kein FUSE gibt.

Abweichungen vom Build am Spielrechner:

- **Shader:** `--no-prepare-shaders`. Der Container hat keine Grafikkarte; das Spiel bereitet die Shader beim ersten
  Start auf dem Zielrechner vor (dauert dort einige Minuten).
- **Update-Angebot des Spiels aus:** `HOOKSHOT_NO_UPDATE_CHECK=1` in `hookshot_env.txt` des Spielordners. Das Angebot
  würde den Builder starten, der den Ordner gebaut hat, und der liegt im Container. Updates baut „Alles bauen".
- **CPU:** Upstream baut für die x86-64-Stufe des bauenden Rechners (`nx2/host_cpu.py`), mit AVX2 also `x86-64-v3`.
  Der Zielrechner braucht dann ebenfalls AVX2, FMA, BMI2 und MOVBE.

## Release wählen

Die Web-UI listet alle Releases von Hookshot/Hookshot: stabile, Vorabversionen (rc) und `nightly`, den
Entwicklungsstand. Die Auswahl liegt in `/config/ref`, gilt ab dem nächsten „Alles bauen" und geht vor `HOOKSHOT_REF`.
`latest` folgt immer dem neuesten stabilen Release. Die Liste kommt aus den Git-Tags, ergänzt um Datum und Vorab-Kennzeichen aus Forgejos API.
Welche AppImage zu einem Release gehört, liest der Container aus dessen `Release-Prüfsummen (SHA-256 oder SHA-1 aus dem zsync-Header)`.

## Longshot

In der Web-UI unter **Projekt** zwischen Hookshot und Longshot wählen (gespeichert in `/config/project`, geht vor
`PROJECT`). Grundlage ist der Abschnitt „Linux, the AppImage from the command line" im
[Longshot-README](https://git.magicbean.dev/MagicBeanDev/Longshot/src/branch/main/README.md#build-from-source) und
[docs/releases.md](https://git.magicbean.dev/MagicBeanDev/Longshot/src/branch/main/docs/releases.md). Der Container nimmt
den Builder `Longshot-<version>-x86_64.AppImage` von
[Longshots Releases](https://git.magicbean.dev/MagicBeanDev/Longshot/releases), nicht den Longshot Launcher von
[longshot.magicbean.dev/install](https://longshot.magicbean.dev/install/): der Launcher hat ein Fenster, der Builder baut
per `--cli`, und der Launcher baut selbst mit genau diesem Builder.

Unterschiede zu Hookshot:

| | Hookshot | Longshot |
| --- | --- | --- |
| Quelle | `git.notrexed.dev/Hookshot/Hookshot` | `git.magicbean.dev/MagicBeanDev/Longshot` |
| Prüfung | SHA-256 aus `SHA256SUMS` oder SHA-1 aus dem zsync-Header | SHA-256 aus `SHA256SUMS`, dessen Signatur `SHA256SUMS.sig` (ECDSA P-256) gegen den Release-Schlüssel aus Longshots `scripts/release_keys.json` per `openssl` geprüft wird. Ohne gültige Signatur wird nichts entpackt |
| Build-Werkzeuge | in der AppImage | lädt der erste `--cli` nach `/config/home/.local/share/longshot/builder/toolchains` (rund 500 MB) |
| Zustand | `/config/builder`, `/config/work`, `/config/ref` | `/config/longshot/…` |
| Spielordner | `/output` | `/output-longshot` (eigener Pfad im Template) |
| Start auf dem Zielrechner | `./hookshot` | `./longshot` (Spiel: `bin/longshot`, Spielstände `~/.local/share/longshot`) |
| Variablen | `HOOKSHOT_*` | `LONGSHOT_*` (`build.sh` setzt Speicher- und Job-Werte mit dem passenden Prefix) |
| Releases | stabile, rc, `nightly` | Longshot hat noch kein stabiles Release: `latest` nimmt dann die neueste Vorabversion (derzeit `v3.0.0-rc.5`). Nightlies heißen `nightly-<n>-<commit>`, nur die neuesten fünf bleiben |

Ohne `LONGSHOT_KEEP_BUILD_FILES=1` löscht Longshot die Build-Dateien (rund 4 GB) nach dem Build; ein Update kompiliert
dann alles neu. Ob das Spiel `LONGSHOT_NO_UPDATE_CHECK=1` aus `longshot_env.txt` liest, ist ungeprüft (im Quelltext
setzen es nur die Startskripte); der Eintrag schadet nicht.

Spielstände von Hookshot übernimmt Longshot nicht automatisch: siehe
[docs/saves.md](https://git.magicbean.dev/MagicBeanDev/Longshot/src/branch/main/docs/saves.md).

## Voraussetzungen

- Die eigene `.nup` in genau dieser Version: Programm `0400486024DEC000`, Update v131072, Build `e0f3ccfa`.
- Rund 60 GB frei während des Builds (Upstream-Angabe), am besten auf SSD/Cache.
- Zielrechner laut Upstream: 64-Bit-Linux mit glibc 2.35 oder neuer, Vulkan-1.3-Treiber mit Mesh-Shadern
  (`vulkaninfo | grep mesh` muss `VK_EXT_mesh_shader` nennen), 16 GB RAM, 8 GB VRAM empfohlen.

## Installation (Unraid)

```bash
mkdir -p /boot/config/plugins/dockerMan/templates-user
curl -fsSL -o /boot/config/plugins/dockerMan/templates-user/my-hookshot-linux-builder.xml \
  https://raw.githubusercontent.com/cosmicflow2512/hookshot-linux-builder/main/unraid/hookshot-linux-builder.xml
```

Danach unter Docker → Add Container das Template `hookshot-linux-builder` wählen und die Web-UI öffnen (Port 8485).

## Spielen

Auf dem Zielrechner im Spielordner `./hookshot` starten (das Spiel selbst ist `bin/hookshot`). Spielstände liegen
unter `~/.local/share/hookshot`.

## Deploy

Beim ersten Start erzeugt der Container einen SSH-Schlüssel unter `/config/ssh`. Der öffentliche Teil steht in der
Web-UI und im Container-Log und gehört auf dem Zielrechner in `~/.ssh/authorized_keys`. `DEPLOY_TARGET` hat die Form
`benutzer@rechner:/pfad/zum/Spielordner`. Der erste Lauf kopiert auch das romfs, spätere nur Geändertes.

## Speicher

Das Template begrenzt den Container mit `--memory=6g --memory-swap=6g`. Upstream teilt Compiler und Lift-Worker nach
dem freien RAM des Hosts ein und sieht ein Container-Limit nicht. Mit Limit setzt `build.sh` deshalb
`HOOKSHOT_MEM_LIMIT_GB` (Limit minus 2 GB) und `HOOKSHOT_LIFT_JOBS` (1 unter 10 GB) selbst. Mehr Limit heißt mehr
Compiler gleichzeitig. Ohne Limit (Extra Parameters leeren) entscheidet Upstream.

## Variablen

| Variable | Standard | Bedeutung |
| --- | --- | --- |
| `NUP_FILE` | leer | Pfad der `.nup` im Container. Leer: erste `.nup` mit `0400486024DEC000` im Namen unter `/nup` |
| `PROJECT` | `hookshot` | `hookshot` oder `longshot`, solange in der Web-UI nichts gewählt ist |
| `HOOKSHOT_REF` | `latest` | Vorgabe, solange in der Web-UI nichts gewählt ist: `latest` = neuestes stabiles Release, oder ein Release-Tag (`v2.1.0`, `v2.2.0-rc.1`, `nightly`) |
| `LONGSHOT_REF` | `latest` | wie `HOOKSHOT_REF`, für Longshot (`v3.0.0-rc.5`, `nightly-348-689a4345`) |
| `LONGSHOT_OUT_DIR` | `/output-longshot` | Spielordner von Longshot im Container |
| `LONGSHOT_DEPLOY_TARGET` | leer | Deploy-Ziel für Longshot |
| `LONGSHOT_KEEP_BUILD_FILES` | leer | `1`: Build-Dateien behalten, Updates kompilieren nur Geändertes |
| `LANGUAGE` | `de` | Spielsprache, wird in `language.txt` geschrieben |
| `DEPLOY_TARGET` | leer | `benutzer@rechner:/pfad` für das Deploy |
| `DEPLOY_PORT` | `22` | SSH-Port |
| `AUTO_DEPLOY` | `false` | nach „Alles bauen" automatisch deployen |
| `PUID` / `PGID` | `99` / `100` | Besitzer des Spielordners nach dem Build |
| `RUN_ON_START` | `false` | beim Containerstart sofort bauen |
| `JOBS` | leer | Compiler gleichzeitig (`HOOKSHOT_JOBS`) |
| `HOOKSHOT_MEM_LIMIT_GB` | Limit − 2 GB | GB, die die Compiler zusammen nehmen dürfen (bei Longshot als `LONGSHOT_MEM_LIMIT_GB` übergeben) |
| `HOOKSHOT_LIFT_JOBS` | 1 unter 10 GB | Emit-Prozesse des Lifts (bei Longshot `LONGSHOT_LIFT_JOBS`) |
| `EXTRA_ARGS` | leer | weitere Optionen für `nx2/make_game.py`, z. B. `--fsr` |

Liegt keine `.nup` unter `/nup`, baut der Container einen früher gebauten Spielordner mit `--update` aus den
Spieldateien neu, die der Ordner behält.

Kommandozeile ohne Web-UI: `docker exec -it hookshot-linux-builder /app/scripts/build.sh all`
(Projekt für einen Lauf: `docker exec -it -e PROJECT=longshot …`, sofern `/config/project` fehlt).

## Lizenz

GPL-3.0, wie Hookshot. Das Icon stammt aus Hookshot (`assets/hookshot.png`).
