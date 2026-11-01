#!/usr/bin/env python3
"""Downloads the Godot editor (Linux, runs headless) and the Windows release template into ./godot_dl.
The templates archive is 1.2 GB: only one member is fetched, with HTTP range requests."""
import os, subprocess, sys, urllib.request, zipfile

V = os.environ.get("GODOT_VERSION", "4.7.2-stable")
BASE = "https://github.com/godotengine/godot/releases/download/%s/" % V
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "godot_dl")
os.makedirs(out, exist_ok=True)
ed = os.path.join(out, "godot")
if not os.path.exists(ed):
    zp = os.path.join(out, "editor.zip")
    urllib.request.urlretrieve(BASE + "Godot_v%s_linux.x86_64.zip" % V, zp)
    with zipfile.ZipFile(zp) as z:
        z.extract("Godot_v%s_linux.x86_64" % V, out)
    os.rename(os.path.join(out, "Godot_v%s_linux.x86_64" % V), ed)
    os.chmod(ed, 0o755)
    os.remove(zp)
tpl = os.path.join(out, "windows_release_x86_64.exe")
if not os.path.exists(tpl):
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote_unzip.py"),
                    BASE + "Godot_v%s_export_templates.tpz" % V, out, "templates/windows_release_x86_64.exe"], check=True)
assert os.path.getsize(tpl) > 50_000_000, "template download looks broken"
print("ok", ed, tpl)
