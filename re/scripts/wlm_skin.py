"""Compiles WLM 8.1's DirectUI resources into a skin directory for the Messenger apps.

usage: wlm_skin.py msgsres.dll msgslang.dll OUTDIR [--icon ctticon.ico]
       # write OUTDIR/skin.json + OUTDIR/img/*.png (+ OUTDIR/icon/*.png from the installer's .ico)
       wlm_skin.py msgsres.dll msgslang.dll --annotate N  # print stylesheet N with references resolved

Resource kinds (see docs/RE-FINDINGS.md §5):
  4000 values/images  (RLE, PNG/GIF/JPEG, C/D colour, V/H gradient, S sysint, J alias, N none, T/F theme part)
  4002 colours        (C/D r,g,b,a | S sysindex | J alias)
  4003 rects          (4 × int32)
  4004 UI layouts     (DirectUI UIFILE markup)
  4005 stylesheets
  4006 alternate RLE images paired with 4000 RLEs
  RT_STRING in msgslang.dll for rcstr()/rcint()
"""
import json, os, re, runpy, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
rle = runpy.run_path(os.path.join(HERE, 'wlm_rle.py'))

# Windows XP (Luna) GetSysColor defaults, as 0xRRGGBB, for 'S' colours.
SYSCOLORS = {
    0: 0xD4D0C8, 1: 0x004E98, 2: 0x0054E3, 3: 0x7A96DF, 4: 0xFFFFFF, 5: 0xFFFFFF, 6: 0x000000,
    7: 0x000000, 8: 0x000000, 9: 0xFFFFFF, 10: 0xD4D0C8, 11: 0xD8E4F8, 12: 0x808080, 13: 0x316AC5,
    14: 0xFFFFFF, 15: 0xECE9D8, 16: 0xACA899, 17: 0xACA899, 18: 0x000000, 19: 0xD8E4F8, 20: 0xFFFFFF,
    21: 0x716F64, 22: 0xF1EFE2, 23: 0x000000, 24: 0xFFFFE1, 26: 0x000080, 27: 0x3D95FF, 28: 0x9DB9EB,
    29: 0x316AC5, 30: 0xECE9D8,
}


def pe_resources(path):
    """Minimal .rsrc walker → {(type, name, lang): bytes}; names are ints or strings."""
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3C)[0]
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    optsz = struct.unpack_from('<H', d, pe + 20)[0]
    rsrc_rva = struct.unpack_from('<I', d, pe + 24 + 96 + 2 * 8)[0]
    secs = []
    o = pe + 24 + optsz
    for _ in range(nsec):
        vsz, va, rsz, raw = struct.unpack_from('<IIII', d, o + 8)
        secs.append((va, max(vsz, rsz), raw))
        o += 40

    def off(rva):
        for va, sz, raw in secs:
            if va <= rva < va + sz:
                return raw + rva - va
        raise ValueError(hex(rva))

    base = off(rsrc_rva)

    def name(entry):
        n = struct.unpack_from('<I', d, entry)[0]
        if n & 0x80000000:
            p = base + (n & 0x7FFFFFFF)
            ln = struct.unpack_from('<H', d, p)[0]
            return d[p + 2:p + 2 + 2 * ln].decode('utf-16le')
        return n

    def walk(dir_off, path):
        named, ids = struct.unpack_from('<HH', d, base + dir_off + 12)
        for i in range(named + ids):
            e = base + dir_off + 16 + 8 * i
            target = struct.unpack_from('<I', d, e + 4)[0]
            p = path + (name(e),)
            if target & 0x80000000:
                yield from walk(target & 0x7FFFFFFF, p)
            else:
                rva, size = struct.unpack_from('<II', d, base + target)
                yield p, d[off(rva):off(rva) + size]

    return dict(walk(0, ()))


def by_type(res, t):
    return {k[1]: v for k, v in res.items() if k[0] == t}


def strings(res):
    out = {}
    for block, b in by_type(res, 6).items():
        p = 0
        for i in range(16):
            if p + 2 > len(b):
                break
            n = struct.unpack_from('<H', b, p)[0]
            p += 2
            if n:
                out[(block - 1) * 16 + i] = b[p:p + 2 * n].decode('utf-16le')
            p += 2 * n
    return out


def color(b, colors=None):
    """'C'/'D' r,g,b,a → '#rrggbbaa'; 'S' sys index; 'J' alias into 4002."""
    tag = b[:1]
    if tag in (b'C', b'D'):
        r, g, bl, a = b[1:5]
        return '#%02x%02x%02x%02x' % (r, g, bl, a)
    if tag == b'S':
        idx = struct.unpack_from('<I', b, 1)[0]
        rgb = SYSCOLORS.get(idx & 0xFFFFFF, 0)
        return '#%06x%02x' % (rgb, idx >> 24)
    if tag == b'J':
        alias = struct.unpack_from('<H', b, 1)[0]
        return {'alias': alias}
    return None


def value(b):
    """Decodes a non-image 4000 value."""
    tag = b[:1]
    if tag in (b'C', b'D', b'S'):
        return {'color': color(b)}
    if tag in (b'V', b'H'):
        return {'gradient': 'vertical' if tag == b'V' else 'horizontal', 'from': color(b[1:6]), 'to': color(b[6:11])}
    if tag == b'J':
        return {'alias': struct.unpack_from('<H', b, 1)[0]}
    if tag == b'N':
        return {'none': True}
    if tag == b'T':
        part, state, cls = struct.unpack_from('<HHH', b, 1)
        return {'theme': {'class': cls, 'part': part, 'state': state}}
    if tag == b'F':
        return {'framecontrol': list(struct.unpack_from('<HH', b, 1))}
    return None


def compile_skin(msgsres, msgslang, out):
    res, lang = pe_resources(msgsres), pe_resources(msgslang)
    os.makedirs(os.path.join(out, 'img'), exist_ok=True)
    skin = {'colors': {}, 'values': {}, 'rects': {}, 'images': {}, 'strings': {}, 'layouts': {}, 'styles': {}}
    for rid, b in by_type(res, 4002).items():
        skin['colors'][rid] = color(b)
    for rid, b in by_type(res, 4003).items():
        skin['rects'][rid] = list(struct.unpack('<4i', b[:16]))
    alt = by_type(res, 4006)
    for rid, b in by_type(res, 4000).items():
        name = None
        if b[:3] == b'RLE':
            frames, mode = rle['decode'](b)
            w, h, px = rle['assemble'](frames[0], mode)
            name = f'{rid}.png'
            open(os.path.join(out, 'img', name), 'wb').write(rle['png'](w, h, px))
            info = {'file': name, 'size': [w, h], 'frames': len(frames), 'slices': mode}
            for i, fr in enumerate(frames[1:], start=1):
                fw, fh, fpx = rle['assemble'](fr, mode)
                open(os.path.join(out, 'img', f'{rid}_{i}.png'), 'wb').write(rle['png'](fw, fh, fpx))
            if mode:
                # Nine-slice cap insets (left, top, right, bottom) from the piece sizes.
                pieces = frames[0]
                cols = 1 + (mode & 1) + (mode >> 2 & 1)
                left = pieces[0][0] if mode & 1 else 0
                right = pieces[cols - 1][0] if mode & 4 else 0
                top = pieces[0][1] if mode & 2 else 0
                bottom = pieces[-1][1] if mode & 8 else 0
                info['insets'] = [left, top, right, bottom]
            if rid in alt and alt[rid][:3] == b'RLE':
                af, am = rle['decode'](alt[rid])
                aw, ah, apx = rle['assemble'](af[0], am)
                open(os.path.join(out, 'img', f'{rid}-alt.png'), 'wb').write(rle['png'](aw, ah, apx))
                info['alt'] = f'{rid}-alt.png'
            skin['images'][rid] = info
        elif b[:8] == b'\x89PNG\r\n\x1a\n' or b[:4] == b'GIF8' or b[:2] == b'\xff\xd8':
            ext = 'png' if b[:1] == b'\x89' else ('gif' if b[:1] == b'G' else 'jpg')
            name = f'{rid}.{ext}'
            open(os.path.join(out, 'img', name), 'wb').write(b)
            skin['images'][rid] = {'file': name}
        else:
            v = value(b)
            if v is not None:
                skin['values'][rid] = v
    for rid, b in by_type(res, 4004).items():
        skin['layouts'][rid] = b.decode('latin-1')
    for rid, b in by_type(res, 4005).items():
        skin['styles'][rid] = b.decode('latin-1')
    skin['strings'] = strings(lang) | strings(res)
    skin['emoticons'], skin['emoticonAnimations'], skin['emoticonNames'] = export_emoticons(res, skin['strings'], out)
    with open(os.path.join(out, 'skin.json'), 'w') as f:
        json.dump(skin, f, ensure_ascii=False, indent=0, sort_keys=True)
    return skin


def bmp_rgba(dib):
    """RT_BITMAP DIB (8/24/32 bpp, bottom-up) → (w, h, RGBA bytes)."""
    hs, w, h, _, bpp, comp = struct.unpack_from('<IiiHHI', dib, 0)
    ncol = struct.unpack_from('<I', dib, 32)[0] or (1 << bpp if bpp <= 8 else 0)
    pal = [dib[hs + 4 * i:hs + 4 * i + 3] for i in range(ncol)]
    px = hs + 4 * ncol
    stride = ((w * bpp + 31) // 32) * 4
    out = bytearray(w * abs(h) * 4)
    for y in range(abs(h)):
        row = px + (abs(h) - 1 - y if h > 0 else y) * stride
        for x in range(w):
            if bpp == 8:
                b, g, r = pal[dib[row + x]]
            elif bpp == 24:
                b, g, r = dib[row + 3 * x:row + 3 * x + 3]
            else:
                b, g, r = dib[row + 4 * x:row + 4 * x + 3]
            o = (y * w + x) * 4
            out[o:o + 4] = bytes((r, g, b, 0 if (r, g, b) == (255, 0, 255) else 255))
    return w, abs(h), out


def png_rgba(b):
    """Decodes an 8-bit, non-interlaced PNG (RGBA, RGB or palette) → (w, h, RGBA bytes)."""
    pos, idat, plte, trns = 8, b'', b'', b''
    while pos < len(b):
        n, kind = struct.unpack_from('>I4s', b, pos)
        body = b[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif kind == b'PLTE':
            plte = body
        elif kind == b'tRNS':
            trns = body
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    if depth != 8 or interlace or ctype not in (2, 3, 6):
        raise ValueError(f'unsupported PNG: depth {depth}, colour type {ctype}, interlace {interlace}')
    bpp = {2: 3, 3: 1, 6: 4}[ctype]
    raw, stride = zlib.decompress(idat), w * bpp
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + prev[x]) & 255
            elif f == 3:
                line[x] = (line[x] + (a + prev[x]) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(prev[x] - c), abs(a - c), abs(a + prev[x] - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else prev[x] if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    out = bytearray(w * h * 4)
    for y, line in enumerate(rows):
        for x in range(w):
            o = (y * w + x) * 4
            if ctype == 6:
                out[o:o + 4] = line[4 * x:4 * x + 4]
            elif ctype == 2:
                out[o:o + 4] = line[3 * x:3 * x + 3] + b'\xff'
            else:
                i = line[x]
                out[o:o + 4] = plte[3 * i:3 * i + 3] + bytes((trns[i] if i < len(trns) else 255,))
    return w, h, out


def crop(w, rgba, x0, cw, h):
    """Columns x0..x0+cw of a w-wide RGBA image."""
    return b''.join(bytes(rgba[(y * w + x0) * 4:(y * w + x0 + cw) * 4]) for y in range(h))


def export_emoticons(res, strings, out):
    """WLM's emoticons, as msnmsgr.exe draws them (FUN_0046d3e1; see re/data/emoticons.json):
    19x19 cells of the 32-bit PNG 202, and frame strips for the animated 108-118. Bitmap 124, the
    client's 8-bit fallback, is used only if PNG 202 is missing. Writes OUTDIR/emoticons/<index>.png
    (+ <index>_<frame>.png) and returns (shortcuts, animations, names)."""
    table = os.path.join(HERE, '..', 'data', 'emoticons.json')
    values, dib = by_type(res, 4000), by_type(res, 2).get(124)
    strip = values.get(202, b'')
    if not os.path.exists(table) or (strip[:8] != b'\x89PNG\r\n\x1a\n' and dib is None):
        return None, None, None
    data = json.load(open(table))
    w, h, px = png_rgba(strip) if strip[:8] == b'\x89PNG\r\n\x1a\n' else bmp_rgba(dib)
    folder = os.path.join(out, 'emoticons')
    os.makedirs(folder, exist_ok=True)
    have = set()
    for i in range(w // h):
        open(os.path.join(folder, f'{i}.png'), 'wb').write(rle['png'](h, h, crop(w, px, i * h, h, h)))
        have.add(i)
    animations = {}
    for idx, a in data['animated'].items():
        blob = values.get(a['resource'], b'')
        if blob[:8] != b'\x89PNG\r\n\x1a\n':
            continue
        sw, sh, spx = png_rgba(blob)
        fw = sw // a['frames']
        for f in range(a['frames']):
            name = f'{idx}.png' if f == 0 else f'{idx}_{f}.png'
            open(os.path.join(folder, name), 'wb').write(rle['png'](fw, sh, crop(sw, spx, f * fw, fw, sh)))
        animations[idx] = {'frames': a['frames'], 'once': a['once'], 'interval': 250}
        have.add(int(idx))
    static = {int(k): v for k, v in data['static'].items()}
    for idx, a in animations.items():
        if static.get(int(idx)) in have:
            a['still'] = static[int(idx)]  # shown where WLM doesn't animate (pickers, lists)
    shortcuts = {}
    for code, idx in data['shortcuts'].items():
        idx = idx if idx in have else static.get(idx)
        if idx is not None:
            shortcuts[code] = idx
    names = {int(i): strings[sid] for i, sid in data['names'].items() if sid in strings and int(i) in have}
    return shortcuts, animations, names


def export_icon(ico_path, out):
    """The installer's Messenger icon (.ico): PNG entries as-is, 32-bit DIB entries converted."""
    d = open(ico_path, 'rb').read()
    _, kind, count = struct.unpack_from('<HHH', d, 0)
    os.makedirs(os.path.join(out, 'icon'), exist_ok=True)
    best = {}
    for i in range(count):
        w, h, _, _, _, bpp, size, offset = struct.unpack_from('<BBBBHHII', d, 6 + 16 * i)
        w, h = w or 256, h or 256
        blob = d[offset:offset + size]
        if blob[:8] == b'\x89PNG\r\n\x1a\n':
            png = blob
        elif struct.unpack_from('<H', blob, 14)[0] == 32:
            stride = w * 4
            rgba = bytearray(w * h * 4)
            for y in range(h):
                src = 40 + (h - 1 - y) * stride
                for x in range(w):
                    b, g, r, a = blob[src + 4 * x:src + 4 * x + 4]
                    rgba[(y * w + x) * 4:(y * w + x) * 4 + 4] = bytes((r, g, b, a))
            png = rle['png'](w, h, rgba)
        else:
            continue
        if w not in best or len(png) > len(best[w]):
            best[w] = png
    for w, png in best.items():
        open(os.path.join(out, 'icon', f'{w}.png'), 'wb').write(png)
    return sorted(best)


def annotate(skin, sheet):
    """Inline-resolve rc*(N) references in a stylesheet for reading."""
    def sub(m):
        kind, n = m.group(1), int(m.group(2))
        if kind == 'rcclr':
            v = skin['colors'].get(n)
        elif kind in ('rcimg', 'rcbkd', 'rcbmp'):
            v = skin['images'].get(n, {}).get('file') or skin['values'].get(n)
        elif kind == 'rcrect':
            v = skin['rects'].get(n)
        else:
            v = skin['strings'].get(n)
        return f'{m.group(0)}⟨{v}⟩'
    return re.sub(r'(rc[a-z]+)\((\d+)\)', sub, skin['styles'][sheet])


if __name__ == '__main__':
    if '--annotate' in sys.argv:
        import tempfile
        tmp = tempfile.mkdtemp()
        skin = compile_skin(sys.argv[1], sys.argv[2], tmp)
        skin = json.load(open(os.path.join(tmp, 'skin.json')))
        skin = {k: {int(i): v for i, v in (d or {}).items()} for k, d in skin.items() if k != 'emoticons'}
        print(annotate(skin, int(sys.argv[sys.argv.index('--annotate') + 1])))
    else:
        s = compile_skin(sys.argv[1], sys.argv[2], sys.argv[3])
        if '--icon' in sys.argv:
            sizes = export_icon(sys.argv[sys.argv.index('--icon') + 1], sys.argv[3])
            print(f'icon: {sizes}')
        print(f"skin: {len(s['images'])} images, {len(s['colors'])} colours, {len(s['values'])} values, "
              f"{len(s['strings'])} strings, {len(s['layouts'])} layouts, {len(s['styles'])} stylesheets, "
              f"{len(s['emoticons'] or {})} emoticon shortcuts")
