"""Web-UI fuer hookshot-linux-builder: Stufen starten, Log mitlesen, Stand anzeigen. Nur Python-Standardbibliothek."""
import glob
import http.server
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.parse
import urllib.request

CONFIG = os.environ.get("CONFIG_DIR", "/config")
OUT = os.environ.get("OUT_DIR", "/output")
LOGS = os.path.join(CONFIG, "logs")
PORT = int(os.environ.get("WEBUI_PORT", "8485"))
STAGES = ("check", "all", "update", "build", "deploy")
HERE = os.path.dirname(os.path.abspath(__file__))

REPO = os.environ.get("HOOKSHOT_REPO", "NotRexed/Hookshot")
REF_FILE = os.path.join(CONFIG, "ref")
TAG_RE = re.compile(r"^[A-Za-z0-9._+-]{1,80}$")
RELEASE_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)\.?(\d+)?)?$")
releases_cache = {"time": 0, "data": None}

state = {"proc": None, "stage": None, "started": None, "ended": None, "code": None, "log": None}
lock = threading.Lock()


def start(stage):
    with lock:
        if state["proc"] and state["proc"].poll() is None:
            return False, "es laeuft schon: " + state["stage"]
        os.makedirs(LOGS, exist_ok=True)
        path = os.path.join(LOGS, time.strftime("%Y%m%d-%H%M%S") + "-" + stage + ".log")
        fh = open(path, "wb")
        proc = subprocess.Popen(["bash", "/app/scripts/build.sh", stage], stdout=fh, stderr=subprocess.STDOUT,
                                start_new_session=True)
        state.update(proc=proc, stage=stage, started=time.time(), ended=None, code=None, log=path)
        latest = os.path.join(LOGS, "latest.log")
        try:
            if os.path.lexists(latest):
                os.remove(latest)
            os.symlink(os.path.basename(path), latest)
        except OSError:
            pass

        def wait():
            code = proc.wait()
            fh.close()
            with lock:
                state.update(code=code, ended=time.time())
        threading.Thread(target=wait, daemon=True).start()
        return True, path


def stop():
    with lock:
        p = state["proc"]
        if p and p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            return True
    return False


def read_json(name):
    try:
        with open(os.path.join(CONFIG, name)) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def read_line(path):
    try:
        with open(path) as fh:
            return fh.readline().strip()
    except OSError:
        return None


def current_ref():
    return read_line(REF_FILE) or os.environ.get("HOOKSHOT_REF", "latest")


def release_kind(tag, prerelease=False):
    if tag == "nightly":
        return "nightly"
    m = RELEASE_RE.match(tag)
    return "pre" if prerelease or (m and m.group(4)) else "stable"


def release_order(tag):
    """Neueste zuerst: nach Version, ein fertiges Release vor seinen Vorabversionen"""
    m = RELEASE_RE.match(tag)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), 0 if m.group(4) else 1, m.group(4) or "", int(m.group(5) or 0))


def fetch_releases():
    """Alle Releases von REPO, auch Vorabversionen und nightly: die Git-Tags (git ls-remote) und GitHubs API zusammen.
    Die API kennt Datum und Vorab-Kennzeichen, erlaubt aber ohne Anmeldung nur 60 Abfragen je Stunde, und GitHubs
    Release-Seite fuehrt nicht jedes Release einzeln, dessen Dateien ladbar sind (v2.2.0-rc.1 stand dort nur als
    rollendes "Latest release candidate"). Die Tags sind vollstaendig. Die Sammel-Releases (linux-parts, builder-parts, rc)
    fallen weg: nur v<Zahl>... und nightly bleiben. Ob ein Tag eine Linux-AppImage hat, zeigt sich beim Laden an
    seiner SHA256SUMS"""
    found, sources = {}, []
    try:
        r = subprocess.run(["git", "ls-remote", "--tags", "https://github.com/%s.git" % REPO],
                           capture_output=True, text=True, timeout=30)
        if r.returncode:
            raise RuntimeError(r.stderr.strip()[:200])
        for l in r.stdout.splitlines():
            if "refs/tags/" in l:
                t = l.split("refs/tags/", 1)[1].replace("^{}", "")
                if t == "nightly" or RELEASE_RE.match(t):
                    found[t] = {"tag": t, "kind": release_kind(t), "date": ""}
        sources.append("Git-Tags")
    except Exception as e:
        git_error = str(e)
    try:
        req = urllib.request.Request("https://api.github.com/repos/%s/releases?per_page=100" % REPO,
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "hookshot-linux-builder"})
        with urllib.request.urlopen(req, timeout=15) as r:
            for rel in json.load(r):
                tag = rel.get("tag_name") or ""
                if rel.get("draft") or not (tag == "nightly" or RELEASE_RE.match(tag)):
                    continue
                found[tag] = {"tag": tag, "kind": release_kind(tag, bool(rel.get("prerelease"))),
                              "date": (rel.get("published_at") or "")[:10]}
        sources.append("GitHub-API")
    except Exception:
        pass
    if not sources:
        raise RuntimeError("Release-Liste nicht abrufbar: " + git_error)
    nightly = [x for x in found.values() if x["tag"] == "nightly"]
    rest = sorted((x for x in found.values() if x["tag"] != "nightly"), key=lambda x: release_order(x["tag"]), reverse=True)
    return {"source": " + ".join(sources), "releases": nightly + rest}


def releases(force=False):
    with lock:
        if not force and releases_cache["data"] and time.time() - releases_cache["time"] < 600:
            return releases_cache["data"]
    data = fetch_releases()
    with lock:
        releases_cache.update(time=time.time(), data=data)
    return data


def free_gb(path):
    try:
        st = os.statvfs(path)
        return round(st.f_bavail * st.f_frsize / (1 << 30), 1)
    except OSError:
        return None


def status():
    with lock:
        p = state["proc"]
        running = bool(p and p.poll() is None)
        s = {"running": running, "stage": state["stage"], "started": state["started"], "ended": state["ended"],
             "code": state["code"], "log": state["log"]}
    nup_dir = os.environ.get("NUP_DIR", "/nup")
    s["nup"] = os.environ.get("NUP_FILE") or next(iter(sorted(glob.glob(os.path.join(nup_dir, "*.nup")) +
                                                             glob.glob(os.path.join(nup_dir, "*", "*.nup")))), None)
    s["ref"] = current_ref()
    s["builder"] = read_line(os.path.join(CONFIG, "builder", "current"))
    s["build"] = read_json("build-info.json") if os.path.exists(os.path.join(OUT, "bin", "hookshot")) else None
    s["updates"] = read_json("update-check.json")
    s["deploy_target"] = os.environ.get("DEPLOY_TARGET", "")
    s["pubkey"] = read_line(os.path.join(CONFIG, "ssh", "id_ed25519.pub"))
    s["free_config"] = free_gb(CONFIG)
    s["free_out"] = free_gb(OUT)
    return s


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/":
            with open(os.path.join(HERE, "index.html"), "rb") as fh:
                return self.send(200, fh.read(), "text/html; charset=utf-8")
        if u.path == "/api/status":
            return self.send(200, json.dumps(status()))
        if u.path == "/api/releases":
            try:
                force = urllib.parse.parse_qs(u.query).get("refresh", ["0"])[0] == "1"
                return self.send(200, json.dumps(dict(releases(force), ref=current_ref())))
            except Exception as e:
                return self.send(502, json.dumps({"error": str(e), "ref": current_ref(), "releases": []}))
        if u.path == "/api/log":
            q = urllib.parse.parse_qs(u.query)
            try:
                off = int(q.get("from", ["0"])[0])
            except ValueError:
                off = 0
            path = state["log"] or os.path.join(LOGS, "latest.log")
            try:
                with open(path, "rb") as fh:
                    size = os.fstat(fh.fileno()).st_size
                    if off > size or off < 0:
                        off = 0
                    if off == 0 and size > 400_000:
                        off = size - 400_000
                    fh.seek(off)
                    chunk = fh.read(2_000_000)
            except OSError:
                return self.send(200, json.dumps({"next": 0, "text": ""}))
            return self.send(200, json.dumps({"next": off + len(chunk), "text": chunk.decode("utf-8", "replace")}))
        self.send(404, '{"error":"not found"}')

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/api/run":
            stage = urllib.parse.parse_qs(u.query).get("stage", [""])[0]
            if stage not in STAGES:
                return self.send(400, json.dumps({"ok": False, "msg": "unbekannte Stufe"}))
            ok, msg = start(stage)
            return self.send(200 if ok else 409, json.dumps({"ok": ok, "msg": msg}))
        if u.path == "/api/ref":
            ref = urllib.parse.parse_qs(u.query).get("ref", [""])[0]
            if not TAG_RE.match(ref):
                return self.send(400, json.dumps({"ok": False, "msg": "kein gueltiges Tag"}))
            with lock:
                if state["proc"] and state["proc"].poll() is None:
                    return self.send(409, json.dumps({"ok": False, "msg": "waehrend eines Laufs nicht aenderbar"}))
            with open(REF_FILE, "w") as fh:
                fh.write(ref + "\n")
            return self.send(200, json.dumps({"ok": True, "ref": ref}))
        if u.path == "/api/stop":
            return self.send(200, json.dumps({"ok": stop()}))
        self.send(404, '{"error":"not found"}')


if __name__ == "__main__":
    if os.environ.get("RUN_ON_START", "false") == "true":
        start("all")
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print("Web-UI auf Port %d" % PORT, flush=True)
    srv.serve_forever()
