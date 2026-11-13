# hookshot-linux-builder

Unraid-Container, der [NotRexed/Hookshot](https://github.com/NotRexed/Hookshot) baut: *The Legend of Zelda: Ocarina of
Time* (Switch-2-Version), statisch rekompiliert, als Linux-Spielordner. Aus der eigenen `.nup`, auf dem eigenen Server,
ohne Fenster. Der fertige Ordner läuft auf einem anderen Linux-Rechner (z. B. Linux auf der PS5, Steam Deck).

Im Image sind weder Spieldateien noch Keys oder Builds, auch nicht Hookshot selbst. Der Container lädt zur Laufzeit die
offizielle AppImage des Releases, prüft sie gegen `SHA256SUMS` des Releases und entpackt sie nach `/config`.

## Was er macht

| Stufe | Inhalt |
| --- | --- |
| check | neuestes Release gegen den geladenen Builder und den gebauten Spielordner |
| update | AppImage des gewählten Releases laden (Standard `latest`), SHA-256 prüfen, entpacken |
| build | `AppRun --cli` (das ist `nx2/make_game.py`): `.nup` lesen, Lift, Kompilieren, Spielordner nach `/output` |
| deploy | `/output` per rsync über SSH nach `DEPLOY_TARGET`, ohne `--delete` |

Grundlage ist der Abschnitt „Linux, the AppImage from the command line" im
[Upstream-README](https://github.com/NotRexed/Hookshot/blob/main/readme.md#build-from-source). Die AppImage bringt
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

Die Web-UI listet alle Releases von NotRexed/Hookshot: stabile, Vorabversionen (rc) und `nightly`, den
Entwicklungsstand. Die Auswahl liegt in `/config/ref`, gilt ab dem nächsten „Alles bauen" und geht vor `HOOKSHOT_REF`.
`latest` folgt immer dem neuesten stabilen Release. Die Liste kommt aus den Git-Tags, ergänzt um Datum und Vorab-Kennzeichen aus GitHubs API.
Welche AppImage zu einem Release gehört, liest der Container aus dessen `SHA256SUMS`.

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
| `HOOKSHOT_REF` | `latest` | Vorgabe, solange in der Web-UI nichts gewählt ist: `latest` = neuestes stabiles Release, oder ein Release-Tag (`v2.1.0`, `v2.2.0-rc.1`, `nightly`) |
| `LANGUAGE` | `de` | Spielsprache, wird in `language.txt` geschrieben |
| `DEPLOY_TARGET` | leer | `benutzer@rechner:/pfad` für das Deploy |
| `DEPLOY_PORT` | `22` | SSH-Port |
| `AUTO_DEPLOY` | `false` | nach „Alles bauen" automatisch deployen |
| `PUID` / `PGID` | `99` / `100` | Besitzer des Spielordners nach dem Build |
| `RUN_ON_START` | `false` | beim Containerstart sofort bauen |
| `JOBS` | leer | Compiler gleichzeitig (`HOOKSHOT_JOBS`) |
| `HOOKSHOT_MEM_LIMIT_GB` | Limit − 2 GB | GB, die die Compiler zusammen nehmen dürfen |
| `HOOKSHOT_LIFT_JOBS` | 1 unter 10 GB | Emit-Prozesse des Lifts |
| `EXTRA_ARGS` | leer | weitere Optionen für `nx2/make_game.py`, z. B. `--fsr` |

Liegt keine `.nup` unter `/nup`, baut der Container einen früher gebauten Spielordner mit `--update` aus den
Spieldateien neu, die der Ordner behält.

Kommandozeile ohne Web-UI: `docker exec -it hookshot-linux-builder /app/scripts/build.sh all`.

## Lizenz

GPL-3.0, wie Hookshot. Das Icon stammt aus Hookshot (`assets/hookshot.png`).
