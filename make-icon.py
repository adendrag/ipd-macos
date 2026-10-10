#!/usr/bin/env python3
"""Build the app icon (.icns) from the Infor icon inside the IPD installer.

The build calls this with the InforIcon48x48.ico it unpacks from your installer,
so no Infor artwork has to live in this repository.

Pure standard-library Python (3.6+): no Pillow, no sips/iconutil. The .ico's own
16 and 32 px frames are used as-is; the larger sizes macOS wants are scaled up
from its largest frame with premultiplied-alpha bilinear filtering.

Usage: make-icon.py <InforIcon48x48.ico> <out.icns>
"""
import struct, sys, zlib


def read_ico(path):
    """Return {size: (w, h, rgba bytes)} for each 32-bit frame in the .ico."""
    d = open(path, 'rb').read()
    _, kind, count = struct.unpack_from('<HHH', d, 0)
    if kind != 1:
        raise SystemExit(f'{path}: not an .ico file')
    frames = {}
    for i in range(count):
        w, h, _, _, _, _, size, off = struct.unpack_from('<BBBBHHII', d, 6 + 16 * i)
        w, h = w or 256, h or 256
        blob = d[off:off + size]
        if blob[:8] == b'\x89PNG\r\n\x1a\n':
            frames[w] = ('png', blob)
            continue
        hdr, dw, dh2, _, bpp = struct.unpack_from('<IiiHH', blob, 0)
        if bpp != 32:
            continue                      # only 32-bit BGRA frames are used
        rows = []
        stride = dw * 4
        for y in range(h):                # DIB rows are stored bottom-up
            start = hdr + (h - 1 - y) * stride
            row = blob[start:start + stride]
            out = bytearray(stride)
            out[0::4], out[1::4], out[2::4], out[3::4] = row[2::4], row[1::4], row[0::4], row[3::4]
            rows.append(bytes(out))
        frames[w] = ('rgba', (w, h, b''.join(rows)))
    if not frames:
        raise SystemExit(f'{path}: no usable 32-bit frames')
    return frames


def png(w, h, rgba):
    raw = b''.join(b'\x00' + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))

    def chunk(t, data):
        return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 9))
            + chunk(b'IEND', b''))


def scale(w, h, rgba, n):
    """Bilinear resample to n x n, premultiplying alpha to avoid dark fringes."""
    px = [rgba[i:i + 4] for i in range(0, len(rgba), 4)]
    pm = [(r * a / 255.0, g * a / 255.0, b * a / 255.0, float(a)) for r, g, b, a in px]
    out = bytearray(n * n * 4)
    for y in range(n):
        sy = min(max((y + 0.5) * h / n - 0.5, 0.0), h - 1.0)
        y0 = int(sy); y1 = min(y0 + 1, h - 1); fy = sy - y0
        for x in range(n):
            sx = min(max((x + 0.5) * w / n - 0.5, 0.0), w - 1.0)
            x0 = int(sx); x1 = min(x0 + 1, w - 1); fx = sx - x0
            c00, c10 = pm[y0 * w + x0], pm[y0 * w + x1]
            c01, c11 = pm[y1 * w + x0], pm[y1 * w + x1]
            v = [(c00[k] * (1 - fx) + c10[k] * fx) * (1 - fy) + (c01[k] * (1 - fx) + c11[k] * fx) * fy
                 for k in range(4)]
            a = v[3]
            o = (y * n + x) * 4
            if a > 0:
                out[o:o + 4] = bytes(min(255, int(round(v[k] * 255.0 / a))) for k in range(3)) + bytes([int(round(a))])
    return bytes(out)


def main(src, dst):
    frames = read_ico(src)
    largest = max(frames)
    # OSTypes that accept an embedded PNG payload, and the pixel size each expects.
    plan = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128), ('ic08', 256)]
    chunks = b''
    for ostype, sz in plan:
        kind, data = frames.get(sz, frames[largest])
        if kind == 'png' and sz in frames:
            payload = data
        elif kind == 'rgba' and sz in frames:
            payload = png(*data)
        elif frames[largest][0] == 'rgba':
            w, h, rgba = frames[largest][1]
            payload = png(sz, sz, scale(w, h, rgba, sz))
        else:
            payload = frames[largest][1]  # PNG frame we can't rescale: macOS scales it
        chunks += ostype.encode('ascii') + struct.pack('>I', len(payload) + 8) + payload
    with open(dst, 'wb') as f:
        f.write(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)
    print(f'wrote {dst} from the {largest}x{largest} frame of {src}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
