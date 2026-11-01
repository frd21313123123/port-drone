"""Extract selected members from a remote zip using HTTP range requests."""
import sys, struct, zlib, urllib.request

url, outdir, *patterns = sys.argv[1:]

def final_url(u):
    req = urllib.request.Request(u, method="HEAD")
    with urllib.request.urlopen(req) as r:
        return r.geturl(), int(r.headers["Content-Length"])

def get(u, start, end):
    req = urllib.request.Request(u, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req) as r:
        return r.read()

u, size = final_url(url)
tail = get(u, size - 65536 - 22, size - 1)
i = tail.rfind(b"PK\x05\x06")
_, _, _, _, n, cd_size, cd_off, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
# zip64?
if cd_off == 0xFFFFFFFF or n == 0xFFFF:
    j = tail.rfind(b"PK\x06\x06")
    n, cd_size, cd_off = struct.unpack("<QQQ", tail[j + 32:j + 56])
cd = get(u, cd_off, cd_off + cd_size - 1)
p = 0
entries = []
while p < len(cd) and cd[p:p + 4] == b"PK\x01\x02":
    (_, _, _, _, method, _, _, crc, csize, usize, nl, el, cl, _, _, _, off) = struct.unpack("<IHHHHHHIIIHHHHHII", cd[p:p + 46])
    name = cd[p + 46:p + 46 + nl].decode()
    extra = cd[p + 46 + nl:p + 46 + nl + el]
    # zip64 extra
    q = 0
    while q < len(extra):
        hid, hl = struct.unpack("<HH", extra[q:q + 4])
        if hid == 1:
            vals = extra[q + 4:q + 4 + hl]
            k = 0
            if usize == 0xFFFFFFFF: usize = struct.unpack("<Q", vals[k:k+8])[0]; k += 8
            if csize == 0xFFFFFFFF: csize = struct.unpack("<Q", vals[k:k+8])[0]; k += 8
            if off == 0xFFFFFFFF: off = struct.unpack("<Q", vals[k:k+8])[0]; k += 8
        q += 4 + hl
    entries.append((name, method, csize, usize, off))
    p += 46 + nl + el + cl

if not patterns:
    for e in entries: print(e[0], e[3])
    sys.exit()

import os
for name, method, csize, usize, off in entries:
    if not any(name.endswith(pt) or pt in name and not name.endswith("_console.exe") for pt in patterns):
        continue
    hdr = get(u, off, off + 29)
    nl, el = struct.unpack("<HH", hdr[26:30])
    start = off + 30 + nl + el
    data = get(u, start, start + csize - 1)
    if method == 8:
        data = zlib.decompress(data, -15)
    out = os.path.join(outdir, os.path.basename(name))
    with open(out, "wb") as f:
        f.write(data)
    print("extracted", name, len(data))
