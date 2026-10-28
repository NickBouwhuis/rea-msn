"""Decoder for DirectUI "RLE" images (msgsres.dll resource types 4000/4006).

Ported from msncore.dll (WLM 8.1) via the rea/Ghidra decompile:
  FUN_59124c79..59124eb3  container header / piece lookup
  FUN_59129d1d            frame → pieces (1..9, nine-slice)
  FUN_59130375            per-row decode of three colour planes (R,G,B)
  FUN_591b697c            per-row decode with an alpha plane
  FUN_5912a054            colour run: 2-bit type, N-bit count, 5-bit samples
  FUN_5912aaf4            alpha run: transparent / opaque / per-pixel
  FUN_591a4228/591a49d0   same runs with 8-bit samples (header bit 13; used by the
                          greyscale "colorizable" images, which index a 256-level ramp)
  FUN_591a3fc6            confirms plane order R,G,B

Container:  "RLE" | b3: count(7) has_extra(1) | b4: lenbytes-1 (2) mode (4) | [extra] |
            count*pieces × (len[lenbytes] + frame)
Frame:      u32 hdr (w:12 pal:1 flip:1 b14:1 alpha:1 h:12 offsz-1:2 b30:1)
            + (h-1) row offsets (each relative to its own table slot) + bit-packed rows
"""
import struct, sys, zlib

PIECES = [1, 2, 2, 4, 2, 3, 4, 6, 2, 4, 3, 6, 4, 6, 6, 9]   # DAT_59124cf4
MASKS = [0, 0xFF, 0xFFFF, 0xFFFFFF, 0xFFFFFFFF]              # DAT_59129fe8


class Bits:
    """LSB-first reader over a 16-bit window, advancing one byte at a time."""
    def __init__(self, data, pos):
        self.d, self.p, self.b = data + b'\0\0\0', pos, 0

    def read(self, n):
        v = (self.d[self.p] | self.d[self.p + 1] << 8) >> self.b
        self.b += n
        if self.b > 7:
            self.p += 1
            self.b &= 7
        return v & ((1 << n) - 1)


def run(bits, plane, pos, nbits, depth=5):
    """FUN_5912a054 (5-bit samples, scaled ×8) / FUN_591a4228 (8-bit samples):
    decode one run into plane[pos:]; returns new pos."""
    scale = 8 if depth == 5 else 1
    t = bits.read(2)
    count = bits.read(nbits) + 1
    if t == 0:
        v = bits.read(depth) * scale
        for i in range(count): plane[pos + i] = v
    elif t == 3:
        for i in range(count): plane[pos + i] = bits.read(depth) * scale
    else:
        k = bits.read(3) + 1
        prev = plane[pos - 1] if pos > 0 else 0
        sign = 1 if t == 1 else -1
        for i in range(count):
            prev = (prev + sign * bits.read(k) * scale) & 0xFF
            plane[pos + i] = prev
    return pos + count


def decode_frame(f):
    hdr = struct.unpack_from('<I', f, 0)[0]
    w, h = hdr & 0xFFF, (hdr >> 16) & 0xFFF
    pal, has_alpha = (hdr >> 12) & 1, (hdr >> 15) & 1
    depth = 8 if (hdr >> 13) & 1 else 5
    esz = ((hdr >> 28) & 3) + 1
    nb, b = 1, (min(w, 255) - 1) >> 1
    while b: nb, b = nb + 1, b >> 1
    rgba = bytearray(w * h * 4)
    for y in range(h):
        if y == 0:
            start = 4 + (h - 1) * esz
        else:
            slot = 4 + (y - 1) * esz
            start = slot + (int.from_bytes(f[slot:slot + 4], 'little') & MASKS[esz])
        bits = Bits(f, start)
        R, G, B, A = [0] * (w + 64), [0] * (w + 64), [0] * (w + 64), [255] * (w + 64)
        if not has_alpha:
            r = g = bb = 0
            while min(r, g, bb) < w:
                if r <= min(g, bb) or pal:
                    r = run(bits, R, r, nb, depth)
                    if pal: g = bb = r; continue
                if g <= min(r, bb): g = run(bits, G, g, nb, depth)
                if bb <= min(r, g): bb = run(bits, B, bb, nb, depth)
            cmap = list(range(w))
        else:
            # FUN_591b697c: colour planes only cover non-transparent pixels.
            x = skipped = a_end = r = g = bb = 0
            amap = [0] * (w + 64)
            skip = [False] * (w + 64)
            cmap = [None] * w
            while x < w:
                if x >= a_end:
                    t = bits.read(2)
                    if t == 1:
                        a_end = run(bits, amap, a_end, nb, depth)
                        kind = 1
                    else:
                        n = bits.read(nb) + 1
                        for i in range(n): amap[a_end + i] = 255 if t == 2 else 0
                        a_end += n
                        kind = t
                    if kind == 0:
                        for i in range(x, a_end): skip[i] = True
                        skipped += a_end - x
                        x = a_end
                        continue
                if pal:
                    if skipped + r <= x: r = run(bits, R, r, nb, depth); g = bb = r
                else:
                    if skipped + r <= x: r = run(bits, R, r, nb, depth)
                    if skipped + g <= x: g = run(bits, G, g, nb, depth)
                    if skipped + bb <= x: bb = run(bits, B, bb, nb, depth)
                x = min(skipped + r, skipped + g, skipped + bb, a_end, w)
            skipped = 0
            for xx in range(w):
                if skip[xx]:
                    skipped += 1
                    continue
                cmap[xx] = xx - skipped
            A = amap
        for xx in range(w):
            ci = cmap[xx]
            o = (y * w + xx) * 4
            if pal:
                v = R[ci] if ci is not None and ci >= 0 else 0
                v = v if depth == 8 else (v >> 3) * 255 // 31
                rgba[o:o + 3] = bytes((v,) * 3)
            elif ci is not None and ci >= 0:
                rgba[o:o + 3] = bytes((c | c >> 5) if depth == 5 else c for c in (R[ci], G[ci], B[ci]))
            a = A[xx]
            rgba[o + 3] = a if a in (0, 255) or depth == 8 else min(255, a | a >> 5)
    return w, h, rgba


def decode(blob):
    """Returns a list of frames; each frame is a list of pieces (w, h, rgba)."""
    assert blob[:3] == b'RLE'
    count, extra = blob[3] & 0x7F, blob[3] >> 7
    lenbytes = (blob[4] & 3) + 1
    mode = (blob[4] >> 2) & 0xF
    pos = 5 + ((blob[5] >> 4) * 2 + 1 if extra else 0)
    entries = []
    while len(entries) < count * PIECES[mode]:
        n = int.from_bytes(blob[pos:pos + lenbytes], 'little') & MASKS[lenbytes]
        entries.append(blob[pos + lenbytes:pos + lenbytes + n])
        pos += lenbytes + n
    k = PIECES[mode]
    return [[decode_frame(e) for e in entries[i * k:(i + 1) * k]] for i in range(count)], mode


def assemble(pieces, mode):
    """Lays out nine-slice pieces row-major (left/right = bits 0/2, top/bottom = bits 1/3)."""
    cols = 1 + (mode & 1) + (mode >> 2 & 1)
    rows = 1 + (mode >> 1 & 1) + (mode >> 3 & 1)
    widths = [pieces[c][0] for c in range(cols)]
    heights = [pieces[r * cols][1] for r in range(rows)]
    W, H = sum(widths), sum(heights)
    out = bytearray(W * H * 4)
    oy = 0
    for r in range(rows):
        ox = 0
        for c in range(cols):
            w, h, px = pieces[r * cols + c]
            for y in range(min(h, heights[r])):
                for x in range(min(w, widths[c])):
                    s, d = (y * w + x) * 4, ((oy + y) * W + ox + x) * 4
                    out[d:d + 4] = px[s:s + 4]
            ox += widths[c]
        oy += heights[r]
    return W, H, out


def png(w, h, rgba):
    raw = b''.join(b'\0' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    frames, mode = decode(open(src, 'rb').read())
    w, h, px = assemble(frames[0], mode)
    open(dst, 'wb').write(png(w, h, px))
    print(f'{src}: {len(frames)} frame(s), mode {mode}, {w}x{h}')
