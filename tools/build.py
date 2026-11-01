#!/usr/bin/env python3
"""Builds the clean DroneFlames.exe (the game's PCK embedded in the Windows export template)
and the native-libraries zip.

  python3 tools/build.py --godot /path/to/godot_editor --template windows_release_x86_64.exe \
      --version 0.32.1 --repo owner/name --out dist

The engine finds a PCK appended to its own executable by the 12-byte trailer
[u64 size of the pck][u32 'GDPC'] — the same mechanism the editor's «embed PCK» option uses.
"""
import argparse, hashlib, os, re, shutil, struct, subprocess, sys, tempfile, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAGIC = 0x43504447  # 'GDPC'


def sh(cmd):
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", required=True, help="Godot 4.7.2 editor binary (runs headless, packs the PCK)")
    ap.add_argument("--template", required=True, help="export template exe (windows_release_x86_64.exe)")
    ap.add_argument("--version", required=True)
    ap.add_argument("--repo", default="")
    ap.add_argument("--out", default="dist")
    ap.add_argument("--exe-name", default="DroneFlames.exe")
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="dfbuild_")
    game = os.path.join(work, "game")
    shutil.copytree(os.path.join(ROOT, "game"), game)

    # version + repo for the updater, the version for the lobby / «what's new»
    cfg = os.path.join(game, "pc", "version.cfg")
    s = open(cfg, encoding="utf-8").read()
    s = re.sub(r'^version=.*$', 'version="%s"' % a.version, s, flags=re.M)
    s = re.sub(r'^repo=.*$', 'repo="%s"' % a.repo, s, flags=re.M)
    open(cfg, "w", encoding="utf-8").write(s)
    libs_rev = int(re.search(r'^libs_rev=(\d+)', s, flags=re.M).group(1))
    menus = os.path.join(game, "ui", "menus.gd")
    m = open(menus, encoding="utf-8").read()
    m, n = re.subn(r'^const VERSION: String = ".*"$', 'const VERSION: String = "v%s"' % a.version, m, count=1, flags=re.M)
    assert n == 1, "VERSION constant not found"
    open(menus, "w", encoding="utf-8").write(m)

    pck = os.path.join(work, "game.pck")
    sh([a.godot, "--headless", "--path", os.path.join(ROOT, "tools", "packproj"), "--script", "res://pack.gd", "--", game, pck])
    data = open(pck, "rb").read()
    assert data[:4] == b"GDPC", "not a PCK"

    exe = open(a.template, "rb").read()
    pad = (-len(exe)) % 64
    exe_out = os.path.join(out, a.exe_name)
    with open(exe_out, "wb") as f:
        f.write(exe)
        f.write(b"\0" * pad)
        f.write(data)
        f.write(struct.pack("<QI", len(data), MAGIC))
    os.chmod(exe_out, 0o755)
    print("exe:", exe_out, os.path.getsize(exe_out))

    libs_zip = os.path.join(out, "DroneFlames-libs-r%d.zip" % libs_rev)
    with zipfile.ZipFile(libs_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for fn in sorted(os.listdir(os.path.join(ROOT, "libs"))):
            zi = zipfile.ZipInfo(fn, (2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, open(os.path.join(ROOT, "libs", fn), "rb").read())
    with open(os.path.join(out, "SHA256SUMS.txt"), "w") as f:
        for fn in (a.exe_name, os.path.basename(libs_zip)):
            f.write("%s  %s\n" % (hashlib.sha256(open(os.path.join(out, fn), "rb").read()).hexdigest(), fn))
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
