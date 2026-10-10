#!/usr/bin/env python3
"""Redirect the unguarded String.substring(int) calls inside
BrowserSWT.strDifference() (lawson-httpclient.jar) to
com.lawson.security.authen.httpclient.SafeStr.substring().

Why: strDifference() finds the end of a URL in the browser's text with
indexOf("<"), then substring()s at that index. IE and Edge wrap an XML response
in an HTML shell, so a '<' is always there. WebKit -- the only Browser engine
SWT has on macOS -- returns the bare URL, indexOf gives -1, and substring(-1)
throws. LawsonHttpClient swallows it as "Failed to Launch SWT web browser
control ...Login Failed", which is why CloudSuite SSO fails after you have
already signed in successfully.

How: invokevirtual and invokestatic are both 3 bytes (opcode + u2 index) and the
operand stack shape is identical (String,int -> String), so no offsets, code
lengths or stack map frames change. New constant-pool entries are appended, so
every existing index stays valid.

Usage: patch-browserswt.py <BrowserSWT.class> <output.class>
"""
import struct, sys

SAFESTR = 'com/lawson/security/authen/httpclient/SafeStr'


def parse_cp(d):
    n = struct.unpack_from('>H', d, 8)[0]
    off, i, entries = 10, 1, {}
    while i < n:
        tag = d[off]
        if tag == 1:
            ln = struct.unpack_from('>H', d, off + 1)[0]
            entries[i] = ('Utf8', d[off + 3:off + 3 + ln]); off += 3 + ln
        elif tag in (7, 8, 16, 19, 20):
            entries[i] = (tag, struct.unpack_from('>H', d, off + 1)[0]); off += 3
        elif tag == 15:
            entries[i] = (tag, d[off + 1:off + 4]); off += 4
        elif tag in (5, 6):
            entries[i] = (tag, d[off + 1:off + 9]); off += 9; i += 1
        else:
            entries[i] = (tag, struct.unpack_from('>HH', d, off + 1)); off += 5
        i += 1
    return entries, n, off


def utf8(entries, idx):
    return entries[idx][1].decode('utf-8', 'replace')


def oplen(code, i):
    """Length of the instruction at i -- needed so operand bytes are never
    mistaken for opcodes."""
    op = code[i]
    if op == 0xc4:                                  # wide
        return 6 if code[i + 1] == 0x84 else 4
    if op in (0xaa, 0xab):                          # tableswitch / lookupswitch
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


def members(d, p, entries):
    """Walk a fields[] or methods[] table, returning (end, [(name_idx, attrs)])."""
    cnt = struct.unpack_from('>H', d, p)[0]; p += 2
    out = []
    for _ in range(cnt):
        name_i = struct.unpack_from('>H', d, p + 2)[0]
        ac = struct.unpack_from('>H', d, p + 6)[0]; q = p + 8
        attrs = []
        for _ in range(ac):
            an = struct.unpack_from('>H', d, q)[0]
            al = struct.unpack_from('>I', d, q + 2)[0]
            attrs.append((an, q + 6, al)); q += 6 + al
        out.append((name_i, attrs)); p = q
    return p, out


def main(path, out):
    d = bytearray(open(path, 'rb').read())
    entries, cp_count, cp_end = parse_cp(d)

    target = None
    for idx, (tag, val) in entries.items():
        if tag != 10:
            continue
        ci, nti = val
        nt = entries[nti][1]
        if (utf8(entries, entries[ci][1]) == 'java/lang/String'
                and utf8(entries, nt[0]) == 'substring'
                and utf8(entries, nt[1]) == '(I)Ljava/lang/String;'):
            target = idx; break
    if target is None:
        sys.exit('java/lang/String.substring(I) methodref not found -- already patched?')

    add, nxt = bytearray(), cp_count

    def add_utf8(s):
        nonlocal nxt
        b = s.encode()
        add.extend(b'\x01' + struct.pack('>H', len(b)) + b)
        nxt += 1
        return nxt - 1

    i_clsname = add_utf8(SAFESTR)
    add.extend(b'\x07' + struct.pack('>H', i_clsname)); i_class = nxt; nxt += 1
    i_name = add_utf8('substring')
    i_desc = add_utf8('(Ljava/lang/String;I)Ljava/lang/String;')
    add.extend(b'\x0c' + struct.pack('>HH', i_name, i_desc)); i_nt = nxt; nxt += 1
    add.extend(b'\x0a' + struct.pack('>HH', i_class, i_nt)); i_mref = nxt; nxt += 1

    d[8:10] = struct.pack('>H', nxt)
    d[cp_end:cp_end] = add

    p = cp_end + len(add) + 6
    p += 2 + 2 * struct.unpack_from('>H', d, p)[0]      # interfaces
    p, _ = members(d, p, entries)                       # fields
    p, methods = members(d, p, entries)                 # methods

    patched = 0
    for name_i, attrs in methods:
        if utf8(entries, name_i) != 'strDifference':
            continue
        for an, aoff, al in attrs:
            if utf8(entries, an) != 'Code':
                continue
            clen = struct.unpack_from('>I', d, aoff + 4)[0]
            cstart = aoff + 8
            code = d[cstart:cstart + clen]
            i = 0
            while i < len(code):
                if code[i] == 0xb6 and struct.unpack_from('>H', code, i + 1)[0] == target:
                    d[cstart + i] = 0xb8
                    struct.pack_into('>H', d, cstart + i + 1, i_mref)
                    patched += 1
                i += oplen(code, i)
    if patched == 0:
        sys.exit('no String.substring call found in strDifference -- Infor changed this method')
    open(out, 'wb').write(bytes(d))
    print(f'patched {patched} substring call(s) in strDifference; constant pool {cp_count} -> {nxt}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
