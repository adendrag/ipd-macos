#!/usr/bin/env python3
"""Make the Ctrl+Space variable popup fire on macOS (designer plugin).

VariablePopupList$1.keyPressed tests:

    if (e.stateMask == SWT.CTRL && e.character == 32) ...

Cocoa SWT fills KeyEvent.character from NSEvent.characters(), which is the
*modified* string: with Control held, macOS reports Ctrl+Space as NUL (0), not
32, so the test can never pass. KeyEvent.keyCode is 32 for the space bar on every
platform, so switching the field read fixes macOS and is identical on Windows.

getfield -> getfield is a 3-byte instruction either way, and both fields push an
int (char widens), so no offsets or stack map frames change. New constant-pool
entries are appended; nothing existing is mutated.

Usage: patch-variablepopup.py <VariablePopupList$1.class> <output.class>
"""
import struct, sys


def parse_cp(d):
    n = struct.unpack_from('>H', d, 8)[0]
    off, i, e = 10, 1, {}
    while i < n:
        t = d[off]
        if t == 1:
            ln = struct.unpack_from('>H', d, off + 1)[0]
            e[i] = ('Utf8', d[off + 3:off + 3 + ln]); off += 3 + ln
        elif t in (7, 8, 16, 19, 20):
            e[i] = (t, struct.unpack_from('>H', d, off + 1)[0]); off += 3
        elif t == 15:
            e[i] = (t, d[off + 1:off + 4]); off += 4
        elif t in (5, 6):
            e[i] = (t, d[off + 1:off + 9]); off += 9; i += 1
        else:
            e[i] = (t, struct.unpack_from('>HH', d, off + 1)); off += 5
        i += 1
    return e, n, off


def utf8(e, i):
    return e[i][1].decode('utf-8', 'replace')


def oplen(code, i):
    op = code[i]
    if op == 0xc4:
        return 6 if code[i + 1] == 0x84 else 4
    if op in (0xaa, 0xab):
        p = i + 1 + ((4 - ((i + 1) % 4)) % 4)
        if op == 0xaa:
            lo, hi = struct.unpack_from('>ii', code, p + 4)
            return (p + 12 + 4 * (hi - lo + 1)) - i
        return (p + 8 + 8 * struct.unpack_from('>i', code, p + 4)[0]) - i
    if 0x15 <= op <= 0x19 or 0x36 <= op <= 0x3a or op in (0x10, 0x12, 0xbc, 0xa9):
        return 2
    if 0x99 <= op <= 0xa6 or op in (0x11, 0x13, 0x14, 0x84, 0xa7, 0xa8, 0xc6, 0xc7,
                                    0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8,
                                    0xbb, 0xbd, 0xc0, 0xc1, 0xc5):
        return 3
    if op in (0xb9, 0xba, 0xc8, 0xc9):
        return 5
    return 1


def members(d, p):
    cnt = struct.unpack_from('>H', d, p)[0]; p += 2
    out = []
    for _ in range(cnt):
        ni = struct.unpack_from('>H', d, p + 2)[0]
        di = struct.unpack_from('>H', d, p + 4)[0]
        ac = struct.unpack_from('>H', d, p + 6)[0]; q = p + 8
        attrs = []
        for _ in range(ac):
            an = struct.unpack_from('>H', d, q)[0]
            al = struct.unpack_from('>I', d, q + 2)[0]
            attrs.append((an, q + 6, al)); q += 6 + al
        out.append((ni, di, attrs)); p = q
    return p, out


def main(path, out):
    d = bytearray(open(path, 'rb').read())
    e, cp_count, cp_end = parse_cp(d)

    f_char = None
    for i, (t, v) in e.items():
        if t != 9:                                    # Fieldref
            continue
        ci, nti = v
        nt = e[nti][1]
        if (utf8(e, e[ci][1]) == 'org/eclipse/swt/events/KeyEvent'
                and utf8(e, nt[0]) == 'character' and utf8(e, nt[1]) == 'C'):
            f_char, key_cls = i, ci
            break
    if f_char is None:
        sys.exit('KeyEvent.character fieldref not found -- already patched?')

    add, nxt = bytearray(), cp_count

    def u(s):
        nonlocal nxt
        b = s.encode(); add.extend(b'\x01' + struct.pack('>H', len(b)) + b)
        nxt += 1; return nxt - 1

    i_name = u('keyCode'); i_desc = u('I')
    add.extend(b'\x0c' + struct.pack('>HH', i_name, i_desc)); i_nt = nxt; nxt += 1
    add.extend(b'\x09' + struct.pack('>HH', key_cls, i_nt)); f_key = nxt; nxt += 1

    d[8:10] = struct.pack('>H', nxt)
    d[cp_end:cp_end] = add

    p = cp_end + len(add) + 6
    p += 2 + 2 * struct.unpack_from('>H', d, p)[0]
    p, _ = members(d, p)
    p, methods = members(d, p)

    patched = 0
    for ni, di, attrs in methods:
        if utf8(e, ni) != 'keyPressed':
            continue
        for an, aoff, al in attrs:
            if utf8(e, an) != 'Code':
                continue
            clen = struct.unpack_from('>I', d, aoff + 4)[0]
            cs = aoff + 8
            code = d[cs:cs + clen]
            i = 0
            while i < len(code):
                if code[i] == 0xb4 and struct.unpack_from('>H', code, i + 1)[0] == f_char:
                    struct.pack_into('>H', d, cs + i + 1, f_key)
                    patched += 1
                i += oplen(code, i)
    if patched != 1:
        sys.exit(f'expected one KeyEvent.character read in keyPressed, found {patched}')
    open(out, 'wb').write(bytes(d))
    print(f'switched {patched} character test to keyCode; constant pool {cp_count} -> {nxt}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
