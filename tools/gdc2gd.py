"""Godot 4.7 binary GDScript (tokenizer v101) -> source text."""
import struct, sys, os, math
import zstandard

TOK = ["Empty", "@", "ID", "LIT", "<", "<=", ">", ">=", "==", "!=", "and", "or", "not", "&&", "||", "!",
       "&", "|", "~", "^", "<<", ">>", "+", "-", "*", "**", "/", "%", "=", "+=", "-=", "*=", "**=", "/=",
       "%=", "<<=", ">>=", "&=", "|=", "^=", "if", "elif", "else", "for", "while", "break", "continue",
       "pass", "return", "match", "when", "as", "assert", "await", "breakpoint", "class", "class_name",
       "const", "enum", "extends", "func", "in", "is", "namespace", "preload", "self", "signal", "static",
       "super", "trait", "var", "void", "yield", "[", "]", "{", "}", "(", ")", ",", ";", ".", "..", "...",
       ":", "$", "->", "_", "NEWLINE", "INDENT", "DEDENT", "PI", "TAU", "INF", "NAN", "VCS", "`", "?",
       "ERROR", "EOF"]
T = {n: i for i, n in enumerate(TOK)}
T["ANNOT"], T["ID"], T["LIT"] = 1, 2, 3


class R:
    def __init__(s, b): s.b, s.p = b, 0
    def u32(s):
        v = struct.unpack_from("<I", s.b, s.p)[0]; s.p += 4; return v
    def i32(s):
        v = struct.unpack_from("<i", s.b, s.p)[0]; s.p += 4; return v
    def raw(s, n):
        v = s.b[s.p:s.p + n]; s.p += n; return v
    def string(s):
        n = s.u32(); v = s.raw(n).decode("utf-8"); s.p += (4 - n % 4) % 4; return v


def fmt_float(f):
    if math.isinf(f): return "INF" if f > 0 else "-INF"
    if math.isnan(f): return "NAN"
    r = repr(f)
    if "e" in r or "E" in r:
        m, e = r.lower().split("e")
        if "." not in m: m += ".0"
        return m + "e" + e
    return r


def esc(s):
    out = []
    for c in s:
        if c == "\\": out.append("\\\\")
        elif c == '"': out.append('\\"')
        elif c == "\n": out.append("\\n")
        elif c == "\t": out.append("\\t")
        elif c == "\r": out.append("\\r")
        elif ord(c) < 32: out.append("\\u%04x" % ord(c))
        else: out.append(c)
    return '"' + "".join(out) + '"'


def variant(r):
    h = r.u32(); t = h & 0xFF; f64 = h & (1 << 16)
    if t == 0: return "null"
    if t == 1: return "true" if r.u32() else "false"
    if t == 2:
        if f64: return str(struct.unpack("<q", r.raw(8))[0])
        return str(r.i32())
    if t == 3:
        if f64: return fmt_float(struct.unpack("<d", r.raw(8))[0])
        return fmt_float(struct.unpack("<f", r.raw(4))[0])
    if t == 4: return esc(r.string())
    if t == 21: return "&" + esc(r.string())
    if t == 22:
        n = r.u32()
        assert n & 0x80000000
        nc = n & 0x7FFFFFFF; sc = r.u32(); fl = r.u32()
        if fl & 2: sc += 1
        names = [r.string() for _ in range(nc)]; subs = [r.string() for _ in range(sc)]
        p = ("/" if fl & 1 else "") + "/".join(names)
        if subs: p += ":" + ":".join(subs)
        return "^" + esc(p)
    raise ValueError("variant type %d" % t)


NOSPACE_BEFORE = {",", ")", "]", ".", ":", ";", "}"}
NOSPACE_AFTER = {"(", "[", ".", "$", "@", "{"}
UNARY_PREV = {"(", "[", ",", "=", "+=", "-=", "*=", "/=", "%=", "return", ":", "and", "or", "not", "==", "!=",
              "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "**", "in", "{", "if", "elif", "while", "->", "&&",
              "||", "!", "&", "|", "^", "<<", ">>", "~", "assert", "when", "else", None}


def decompile(data):
    assert data[:4] == b"GDSC", data[:4]
    ver, usize = struct.unpack_from("<II", data, 4)
    body = data[12:] if usize == 0 else zstandard.ZstdDecompressor().decompress(data[12:], max_output_size=usize)
    r = R(body)
    nid, ncon, nlines, ntok = r.u32(), r.u32(), r.u32(), r.u32()
    ids = []
    for _ in range(nid):
        n = r.u32(); cs = r.raw(n * 4)
        ids.append("".join(chr(struct.unpack("<I", bytes(x ^ 0xB6 for x in cs[i * 4:i * 4 + 4]))[0]) for i in range(n)))
    cons = [variant(r) for _ in range(ncon)]
    lines = {}
    for _ in range(nlines):
        ti, ln = r.u32(), r.u32(); lines[ti] = ln
    cols = {}
    for _ in range(nlines):
        ti, c = r.u32(), r.u32(); cols[ti] = c
    toks = []
    for _ in range(ntok):
        b0 = r.b[r.p]
        if b0 & 0x80:
            tt = r.u32(); r.p += 4
        else:
            tt = r.b[r.p]; r.p += 1; r.p += 4
        typ = tt & 0x7F; idx = tt >> 8
        if typ in (1, 2): text = ids[idx]
        elif typ in (3,): text = cons[idx]
        elif typ == T["ERROR"]: text = cons[idx]
        else: text = TOK[typ]
        toks.append((typ, text))
    assert r.p == len(body), (r.p, len(body))

    out = []
    cur = []
    cur_line = 1
    prev = None
    in_dollar = False
    for i, (typ, text) in enumerate(toks):
        if i in lines:
            out.append("".join(cur)); cur = []
            target = lines[i]
            cur_line += 1
            while cur_line < target:
                out.append(""); cur_line += 1
            cur.append("\t" * (cols[i] - 1))
            prev = None
            in_dollar = False
        if typ == 1 and not text.startswith("@"):
            text = "@" + text
        # spacing
        if prev is not None:
            sp = True
            if text in NOSPACE_BEFORE and typ not in (2, 3): sp = False
            if prev in NOSPACE_AFTER: sp = False
            if text in ("(", "[") and typ not in (2, 3) and prev_typ in (2, 3) or (text in ("(", "[") and prev in (")", "]", "self", "super", "preload", "func", "\"")):
                sp = False if prev not in ("in", "and", "or", "not", "return", "if", "elif", "while", ",", "=", "await") else True
            if text == "(" and prev_typ == 2:
                sp = False
            if prev in ("-", "+", "~", "!") and prev_unary: sp = False
            if in_dollar and (text == "/" or prev == "/" or text == "%" or prev == "%"):
                sp = False
            if text == ":" and False: sp = False
            if sp: cur.append(" ")
        unary = text in ("-", "+", "~", "!") and typ not in (2, 3) and (prev in UNARY_PREV or prev_typ == 1 and False)
        if typ == T["$"]: in_dollar = True
        elif in_dollar and not (typ in (2, 3) or text in ("/", "%")): in_dollar = False
        cur.append(text)
        prev = text if typ not in (2, 3) else '"' if typ == 3 and text.startswith('"') else "id"
        prev_typ = typ
        prev_unary = unary
    out.append("".join(cur))
    return "\n".join(out).lstrip("\n") + "\n"


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    n = bad = 0
    for dp, _, fs in os.walk(src):
        for f in fs:
            if not f.endswith(".gdc"): continue
            rel = os.path.relpath(os.path.join(dp, f), src)
            o = os.path.join(dst, rel[:-1])
            os.makedirs(os.path.dirname(o), exist_ok=True)
            try:
                open(o, "w").write(decompile(open(os.path.join(dp, f), "rb").read()))
                n += 1
            except Exception as e:
                bad += 1; print("FAIL", rel, repr(e))
    print("ok", n, "fail", bad)
