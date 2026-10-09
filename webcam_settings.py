#!/usr/bin/env python3
"""Per-physical-camera UVC presets for macOS. Uses the bundled IOKit helper."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import atexit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
UVC = ROOT / "bin" / "uvcctl"
PREVIEW = ROOT / "bin" / "preview"
STATE = Path(os.environ.get("WEBCAM_SETTINGS_STATE", Path.home() / ".config/webcam-settings/presets.json"))
GATES = {"white_balance_temperature_auto": 0, "hue_auto": 0,
         "contrast_auto": 0, "focus_auto": 0, "exposure_auto": 1}


def helper(*args, timeout=90):
    if not UVC.exists():
        raise RuntimeError("USB helper is missing. Run 'make' in the project folder first.")
    run = subprocess.run([str(UVC), *map(str, args)], capture_output=True, text=True,
                         timeout=timeout)
    if run.returncode and not (args and args[0] == "list" and run.stdout.strip() == "[]"):
        raise RuntimeError(run.stderr.strip() or f"uvcctl exited {run.returncode}")
    return run.stdout.strip()


def cameras():
    return json.loads(helper("list", timeout=15))


def device(location):
    matches = [c for c in cameras() if c["location"].lower() == location.lower()]
    if len(matches) != 1:
        raise RuntimeError(f"Camera at USB location {location} is not connected")
    return matches[0]


def caps(cam):
    return json.loads(helper("caps", "-d", cam["id"], "-l", cam["location"]))


def write_control(cam, name, value):
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError("Control value must be an integer")
    return int(helper("set", name, value, "-d", cam["id"], "-l", cam["location"], timeout=12))


def read_state():
    if not STATE.exists():
        return {"version": 1, "presets": []}
    data = json.loads(STATE.read_text())
    if data.get("version") != 1 or not isinstance(data.get("presets"), list):
        raise RuntimeError(f"Unsupported preset file: {STATE}")
    return data


def save_state(data):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".presets-", suffix=".json", dir=STATE.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def identity(cam, all_cams):
    # Some devices ship a serial shared by every unit. A port binding stays safe
    # even if only one of the identical cameras is plugged in during setup.
    return "port"


def save_preset(location, label):
    all_cams = cameras()
    cam = next((c for c in all_cams if c["location"].lower() == location.lower()), None)
    if not cam:
        raise RuntimeError(f"Camera at USB location {location} is not connected")
    spec = caps(cam)
    values = {c["name"]: c["value"] for c in spec["controls"]
              if c["writable"] and c["name"] != "privacy"}
    if not values:
        raise RuntimeError("This camera has no readable, writable standard UVC controls")
    data = read_state()
    data["presets"] = [p for p in data["presets"] if not
                       (p["id"] == cam["id"] and p["location"] == cam["location"])]
    preset = {"label": label.strip() or cam["name"], "id": cam["id"],
              "name": cam["name"], "serial": cam.get("serial", ""),
              "location": cam["location"], "match": identity(cam, all_cams),
              "values": values}
    data["presets"].append(preset)
    save_state(data)
    return preset


def sync_preset(source_location, target_locations):
    """Apply a saved profile to selected matching cameras and store verified copies."""
    if not isinstance(target_locations, list) or not target_locations:
        raise ValueError("Select at least one target camera")
    if any(not isinstance(location, str) for location in target_locations):
        raise ValueError("Target camera locations must be strings")
    normalized = [location.lower() for location in target_locations]
    if len(set(normalized)) != len(normalized):
        raise ValueError("Select each target camera only once")
    if source_location.lower() in normalized:
        raise ValueError("The source camera cannot be a target")

    all_cams = cameras()
    data = read_state()
    source = next((p for p in data["presets"]
                   if p["location"].lower() == source_location.lower()), None)
    if source is None:
        raise ValueError("Save the source camera before syncing its profile")
    resolve(source, all_cams)
    targets = []
    for location in target_locations:
        cam = next((c for c in all_cams if c["location"].lower() == location.lower()), None)
        if cam is None:
            raise ValueError(f"Camera at USB location {location} is not connected")
        if cam["id"] != source["id"]:
            raise ValueError(f"{cam['name']} at port {location} is a different camera model")
        targets.append(cam)

    # Check every selected target before writing to any camera.
    for cam in targets:
        controls = {c["name"]: c for c in caps(cam)["controls"]}
        for name, value in source["values"].items():
            control = controls.get(name)
            if not control or not control["writable"]:
                raise ValueError(f"Port {cam['location']}: {name} is unavailable or read-only")
            if not control["min"] <= value <= control["max"]:
                raise ValueError(f"Port {cam['location']}: {name} cannot accept {value}")

    results = []
    for cam in targets:
        previous = next((p for p in data["presets"] if p["id"] == cam["id"] and
                         p["location"] == cam["location"]), None)
        copied = {"label": previous["label"] if previous else cam["name"],
                  "id": cam["id"], "name": cam["name"],
                  "serial": cam.get("serial", ""), "location": cam["location"],
                  "match": identity(cam, all_cams), "values": dict(source["values"])}
        try:
            result = apply_preset(copied, all_cams)
            if result["ok"]:
                data["presets"] = [p for p in data["presets"] if not
                                   (p["id"] == cam["id"] and p["location"] == cam["location"])]
                data["presets"].append(copied)
        except Exception as exc:
            result = {"label": copied["label"], "location": cam["location"],
                      "ok": False, "errors": [str(exc)]}
        results.append(result)
    if any(result["ok"] for result in results):
        save_state(data)
    return results


def delete_preset(location):
    data = read_state()
    before = len(data["presets"])
    data["presets"] = [p for p in data["presets"] if p["location"] != location]
    if len(data["presets"]) == before:
        raise RuntimeError(f"No saved preset for port {location}")
    save_state(data)


def resolve(preset, all_cams):
    if preset.get("match") == "serial":
        matches = [c for c in all_cams if c["id"] == preset["id"] and
                   c.get("serial") == preset.get("serial")]
    elif preset.get("match") == "port":
        matches = [c for c in all_cams if c["id"] == preset["id"] and
                   c["location"] == preset["location"] and
                   c.get("serial", "") == preset.get("serial", "")]
    else:
        raise RuntimeError(f"Unknown matching method for {preset.get('label', 'camera')}")
    if len(matches) != 1:
        raise RuntimeError(f"{preset['label']}: expected one matching camera, found {len(matches)}. "
                           f"Check its USB port and run 'list'.")
    return matches[0]


def apply_preset(preset, all_cams):
    cam = resolve(preset, all_cams)
    spec = caps(cam)
    supported = {c["name"]: c for c in spec["controls"] if c["writable"]}
    values = preset["values"]
    errors = []
    for name in values:
        if name not in supported:
            errors.append(f"{name}: unavailable or read-only")
    # Disable automatic modes before setting the manual values they control.
    for name, manual in GATES.items():
        if name in values and name in supported:
            try:
                write_control(cam, name, manual)
            except (RuntimeError, ValueError) as exc:
                errors.append(f"{name} manual mode: {exc}")
    for name, value in values.items():
        if name in GATES or name not in supported:
            continue
        try:
            actual = write_control(cam, name, value)
            if actual != value:
                errors.append(f"{name}: requested {value}, camera reports {actual}")
        except (RuntimeError, ValueError) as exc:
            errors.append(f"{name}: {exc}")
    for name, value in values.items():
        if name not in GATES or name not in supported:
            continue
        try:
            actual = write_control(cam, name, value)
            if actual != value:
                errors.append(f"{name}: requested {value}, camera reports {actual}")
        except (RuntimeError, ValueError) as exc:
            errors.append(f"{name}: {exc}")
    # Re-read at the end; some firmware acknowledges writes but ignores them.
    final = {c["name"]: c["value"] for c in caps(cam)["controls"]}
    manually_controlled = {"white_balance_temperature": "white_balance_temperature_auto",
                           "hue": "hue_auto", "contrast": "contrast_auto",
                           "focus_absolute": "focus_auto",
                           "exposure_time_absolute": "exposure_auto", "gain": "exposure_auto"}
    for name, value in values.items():
        if name in supported and final.get(name) != value:
            # Automatic modes are allowed to change their dependent values.
            gate = manually_controlled.get(name)
            if gate and gate in values and values[gate] != GATES[gate]:
                continue
            errors.append(f"{name}: final readback {final.get(name)}, expected {value}")
    return {"label": preset["label"], "location": cam["location"], "ok": not errors,
            "errors": list(dict.fromkeys(errors))}


def apply_all(wait=0):
    presets = read_state()["presets"]
    if not presets:
        raise RuntimeError(f"No presets saved yet. Open the settings page or run 'save'.")
    deadline = time.monotonic() + wait
    while True:
        all_cams = cameras()
        if all(any(c["id"] == p["id"] and
                   (c["location"] == p["location"] if p["match"] == "port" else
                    c.get("serial") == p["serial"]) for c in all_cams) for p in presets):
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(1)
    results = []
    for preset in presets:
        try:
            results.append(apply_preset(preset, all_cams))
        except Exception as exc:
            results.append({"label": preset["label"], "ok": False, "errors": [str(exc)]})
    return results


def obs_pids():
    run = subprocess.run(["/usr/bin/pgrep", "-x", "OBS"], capture_output=True, text=True)
    return {int(line) for line in run.stdout.splitlines() if line.isdigit()}


def capture_id(cam):
    """macOS UVC capture ID encodes USB location and vendor/product IDs."""
    try:
        location = int(cam["location"], 16)
        vid, pid = (int(part, 16) for part in cam["id"].split(":"))
    except (ValueError, KeyError) as exc:
        raise RuntimeError("Cannot map camera to its capture device") from exc
    return f"0x{((location << 32) | (vid << 16) | pid):x}"


def read_exact(pipe, count):
    chunks = []
    while count:
        part = pipe.read(count)
        if not part:
            return None
        chunks.append(part)
        count -= len(part)
    return b"".join(chunks)


class PreviewManager:
    def __init__(self):
        self.lock = threading.RLock()
        self.sessions = {}
        threading.Thread(target=self.reap, daemon=True).start()
        atexit.register(self.stop_all)

    def start(self, cam):
        if not PREVIEW.exists():
            raise RuntimeError("Preview helper is missing. Run 'make bin/preview'.")
        location = cam["location"]
        with self.lock:
            existing = self.sessions.get(location)
            if existing and existing["process"].poll() is None:
                existing["last_request"] = time.monotonic()
                return self.status(location)
            process = subprocess.Popen([str(PREVIEW), capture_id(cam)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       bufsize=0)
            session = {"process": process, "frame": None, "error": None,
                       "started": time.monotonic(), "last_request": time.monotonic()}
            self.sessions[location] = session
            threading.Thread(target=self.read_frames, args=(location, session), daemon=True).start()
        return self.status(location)

    def read_frames(self, location, session):
        process = session["process"]
        try:
            while True:
                header = read_exact(process.stdout, 4)
                if header is None:
                    break
                size = int.from_bytes(header, "big")
                if size < 100 or size > 8_000_000:
                    raise RuntimeError("Invalid frame from capture helper")
                frame = read_exact(process.stdout, size)
                if frame is None:
                    break
                with self.lock:
                    if self.sessions.get(location) is not session:
                        break
                    session["frame"] = frame
        except Exception as exc:
            with self.lock:
                session["error"] = str(exc)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                detail = process.stderr.read().decode(errors="replace").strip()
            except Exception:
                detail = ""
            with self.lock:
                if self.sessions.get(location) is session and not session["error"]:
                    session["error"] = detail or "Camera capture stopped"

    def status(self, location):
        with self.lock:
            session = self.sessions.get(location)
            if not session:
                return {"state": "stopped"}
            session["last_request"] = time.monotonic()
            if session["error"]:
                return {"state": "error", "error": session["error"]}
            if session["frame"]:
                return {"state": "ready"}
            elapsed = time.monotonic() - session["started"]
            return {"state": "waiting", "message":
                    "Waiting for camera access or first frame" if elapsed < 12 else
                    "No preview frames yet. Check macOS Camera permission or whether another app owns this camera."}

    def frame(self, location):
        with self.lock:
            session = self.sessions.get(location)
            if not session:
                return None
            session["last_request"] = time.monotonic()
            return session["frame"]

    def stop(self, location):
        with self.lock:
            session = self.sessions.pop(location, None)
        if session and session["process"].poll() is None:
            session["process"].terminate()

    def stop_all(self):
        with self.lock:
            locations = list(self.sessions)
        for location in locations:
            self.stop(location)

    def reap(self):
        while True:
            time.sleep(5)
            now = time.monotonic()
            with self.lock:
                expired = [location for location, session in self.sessions.items()
                           if now - session["last_request"] > 30]
            for location in expired:
                self.stop(location)


preview_manager = None


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def request_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > 16384:
            raise ValueError("Request too large")
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/":
                data = (ROOT / "index.html").read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif path == "/preview.js":
                data = (ROOT / "preview.js").read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(data)
            elif path == "/api/cameras":
                self.respond(200, {"cameras": cameras(), "presets": read_state()["presets"]})
            elif path.startswith("/api/caps/"):
                self.respond(200, caps(device(path.split("/")[-1])))
            elif path.startswith("/api/preview/status/"):
                self.respond(200, preview_manager.status(path.split("/")[-1]))
            elif path.startswith("/api/preview/frame/"):
                frame = preview_manager.frame(path.split("/")[-1])
                if frame is None:
                    self.respond(503, {"error": "Preview frame not ready"})
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(frame)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(frame)
            else:
                self.respond(404, {"error": "Not found"})
        except Exception as exc:
            self.respond(500, {"error": str(exc)})

    def do_POST(self):
        try:
            body = self.request_json()
            path = urlparse(self.path).path
            if path == "/api/set":
                cam = device(body["location"])
                known = {c["name"]: c for c in caps(cam)["controls"]}
                name = body["name"]
                if name not in known or not known[name]["writable"]:
                    raise ValueError("Control is unavailable or read-only")
                self.respond(200, {"value": write_control(cam, name, body["value"])})
            elif path == "/api/save":
                self.respond(200, save_preset(body["location"], body.get("label", "")))
            elif path == "/api/apply":
                preset = next((p for p in read_state()["presets"]
                               if p["location"] == body["location"]), None)
                if not preset:
                    raise ValueError("Save this camera before reapplying its preset")
                self.respond(200, apply_preset(preset, cameras()))
            elif path == "/api/sync":
                self.respond(200, {"results": sync_preset(body["source"], body["targets"])})
            elif path == "/api/preview/start":
                self.respond(200, preview_manager.start(device(body["location"])))
            elif path == "/api/preview/stop":
                preview_manager.stop(body["location"])
                self.respond(200, {"state": "stopped"})
            else:
                self.respond(404, {"error": "Not found"})
        except Exception as exc:
            self.respond(400, {"error": str(exc)})

    def log_message(self, format, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), format % args))


def main():
    parser = argparse.ArgumentParser(description="Save and restore UVC camera settings")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    sub.add_parser("state")
    inspect = sub.add_parser("inspect")
    inspect.add_argument("location")
    save = sub.add_parser("save")
    save.add_argument("location")
    save.add_argument("label", nargs="?", default="")
    sync = sub.add_parser("sync", help="copy a saved profile to matching cameras")
    sync.add_argument("source", help="source camera USB location")
    sync.add_argument("targets", nargs="+", help="target camera USB locations")
    delete = sub.add_parser("delete")
    delete.add_argument("location")
    setcmd = sub.add_parser("set")
    setcmd.add_argument("location")
    setcmd.add_argument("name")
    setcmd.add_argument("value", type=int)
    apply = sub.add_parser("apply")
    apply.add_argument("--wait", type=int, default=0, help="seconds to wait for cameras")
    serve = sub.add_parser("serve")
    serve.add_argument("--port", type=int, default=8765)
    watch = sub.add_parser("watch")
    watch.add_argument("--interval", type=int, default=3)
    sub.add_parser("install-agent", help="restore presets at login and on camera reconnect")
    sub.add_parser("uninstall-agent")
    sub.add_parser("obs-start", help="open OBS and reapply presets after it starts")
    args = parser.parse_args()
    try:
        if args.command == "list":
            current = cameras()
            presets = read_state()["presets"]
            for cam in current:
                p = next((p for p in presets if p["location"] == cam["location"]), None)
                print(f"{cam['location']}  {cam['name']}  {cam['id']}  serial={cam['serial']}"
                      f"  preset={p['label'] if p else '(none)'}")
        elif args.command == "state":
            print(json.dumps({"cameras": cameras(), "presets": read_state()["presets"]}))
        elif args.command == "inspect":
            print(json.dumps(caps(device(args.location)), indent=2))
        elif args.command == "set":
            print(write_control(device(args.location), args.name, args.value))
        elif args.command == "save":
            print(json.dumps(save_preset(args.location, args.label), indent=2))
        elif args.command == "sync":
            results = sync_preset(args.source, args.targets)
            print(json.dumps(results, indent=2))
            if not all(result["ok"] for result in results):
                return 1
        elif args.command == "delete":
            delete_preset(args.location)
            print(f"Removed preset for port {args.location}")
        elif args.command == "apply":
            results = apply_all(max(0, args.wait))
            print(json.dumps(results, indent=2))
            if not all(r["ok"] for r in results):
                return 1
        elif args.command == "serve":
            global preview_manager
            preview_manager = PreviewManager()
            server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
            print(f"Settings page: http://127.0.0.1:{args.port}", flush=True)
            server.serve_forever()
        elif args.command == "watch":
            previous = set()
            previous_obs = set()
            while True:
                try:
                    now = {(c["id"], c["location"]) for c in cameras()}
                except RuntimeError as exc:
                    print(f"USB scan failed: {exc}", file=sys.stderr, flush=True)
                    time.sleep(max(1, args.interval))
                    continue
                obs_now = obs_pids()
                if (now - previous or obs_now - previous_obs) and read_state()["presets"]:
                    # Let cameras enumerate and OBS finish opening its sources.
                    time.sleep(4 if obs_now - previous_obs else 2)
                    try:
                        for result in apply_all():
                            print(json.dumps(result), flush=True)
                    except RuntimeError as exc:
                        print(exc, file=sys.stderr, flush=True)
                previous = now
                previous_obs = obs_now
                time.sleep(max(1, args.interval))
        elif args.command in ("install-agent", "uninstall-agent"):
            name = "local.webcam-settings.restore"
            path = Path.home() / "Library/LaunchAgents" / (name + ".plist")
            runtime = Path.home() / "Library/Application Support/WebcamSettings"
            subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(path)],
                           capture_output=True)
            if args.command == "install-agent":
                path.parent.mkdir(parents=True, exist_ok=True)
                (runtime / "bin").mkdir(parents=True, exist_ok=True)
                shutil.copy2(Path(__file__).resolve(), runtime / "webcam_settings.py")
                shutil.copy2(UVC, runtime / "bin/uvcctl")
                shutil.copy2(ROOT / "index.html", runtime / "index.html")
                shutil.copy2(ROOT / "preview.js", runtime / "preview.js")
                if PREVIEW.exists():
                    shutil.copy2(PREVIEW, runtime / "bin/preview")
                log_dir = STATE.parent
                log_dir.mkdir(parents=True, exist_ok=True)
                (log_dir / "watch.log").write_text("")
                (log_dir / "watch-error.log").write_text("")
                with path.open("wb") as stream:
                    plistlib.dump({"Label": name, "ProgramArguments":
                                  [sys.executable, str(runtime / "webcam_settings.py"), "watch"],
                                   "RunAtLoad": True, "KeepAlive": True,
                                   "StandardOutPath": str(log_dir / "watch.log"),
                                   "StandardErrorPath": str(log_dir / "watch-error.log")}, stream)
                run = subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}",
                                      str(path)], capture_output=True, text=True)
                if run.returncode:
                    raise RuntimeError(run.stderr.strip() or "launchctl bootstrap failed")
                print(f"Installed and started {path}")
            else:
                path.unlink(missing_ok=True)
                shutil.rmtree(runtime, ignore_errors=True)
                print("Removed webcam restore agent")
        elif args.command == "obs-start":
            run = subprocess.run(["open", "-a", "OBS"], capture_output=True, text=True)
            if run.returncode:
                raise RuntimeError(run.stderr.strip() or "Cannot open OBS")
            time.sleep(4)
            results = apply_all(wait=20)
            print(json.dumps(results, indent=2))
            if not all(r["ok"] for r in results):
                return 1
    except (RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"webcam-settings: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
