#!/usr/bin/env python3
"""Fix the path separator FgProcess.toXMLString(String) uses to derive a process
id from the file being saved (bpm-commons.jar).

Infor's code is:

    if (name.indexOf(".lpd") >= 0)
        name = name.substring(name.lastIndexOf("\\") + 1, name.indexOf(".lpd"));
    xml = PFlowUtils.instance().escapeXmlSpecialCharInProcessName(xml, name);

On macOS lastIndexOf("\\") is -1, so +1 = 0 and the id becomes the whole absolute
path instead of the basename. That is bad on its own, but the real damage is done
downstream: escapeXmlSpecialCharInProcessName splices with

    cut = head.length() + name.length();     // assumes the existing id is this long
    return head + name + xml.substring(cut);

so a name that is longer than the id already in the XML slices through the
attributes that follow it, truncating `" priority=` and producing a file that is
not well-formed XML. The server then refuses it with "process definition was not
able to be loaded".

The fix repoints that one ldc_w at a fresh "/" constant. New constant-pool
entries are appended, the instruction stays 3 bytes, and no shared constant is
mutated -- so nothing else in this 6000-line class is affected.

Usage: patch-fgprocess.py <FgProcess.class> <output.class>
"""
import struct, sys


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
        name_i = struct.unpack_from('>H', d, p + 2)[0]
        desc_i = struct.unpack_from('>H', d, p + 4)[0]
        ac = struct.unpack_from('>H', d, p + 6)[0]; q = p + 8
        attrs = []
        for _ in range(ac):
            an = struct.unpack_from('>H', d, q)[0]
            al = struct.unpack_from('>I', d, q + 2)[0]
            attrs.append((an, q + 6, al)); q += 6 + al
        out.append((name_i, desc_i, attrs)); p = q
    return p, out


def main(path, out):
    d = bytearray(open(path, 'rb').read())
    entries, cp_count, cp_end = parse_cp(d)

    # the String constant whose value is a single backslash
    backslash = [i for i, (t, v) in entries.items()
                 if t == 8 and entries[v][0] == 'Utf8' and utf8(entries, v) == '\\']
    if not backslash:
        sys.exit('no "\\\\" string constant found -- already patched?')

    # append Utf8 "/" + String -> it
    add = bytearray(); nxt = cp_count
    add.extend(b'\x01' + struct.pack('>H', 1) + b'/'); i_utf8 = nxt; nxt += 1
    add.extend(b'\x08' + struct.pack('>H', i_utf8)); i_str = nxt; nxt += 1
    d[8:10] = struct.pack('>H', nxt)
    d[cp_end:cp_end] = add

    p = cp_end + len(add) + 6
    p += 2 + 2 * struct.unpack_from('>H', d, p)[0]
    p, _ = members(d, p)
    p, methods = members(d, p)

    patched = 0
    for name_i, desc_i, attrs in methods:
        if (utf8(entries, name_i) != 'toXMLString'
                or utf8(entries, desc_i) != '(Ljava/lang/String;)Ljava/lang/String;'):
            continue
        for an, aoff, al in attrs:
            if utf8(entries, an) != 'Code':
                continue
            clen = struct.unpack_from('>I', d, aoff + 4)[0]
            cstart = aoff + 8
            code = d[cstart:cstart + clen]
            i = 0
            while i < len(code):
                op = code[i]
                if op == 0x13 and struct.unpack_from('>H', code, i + 1)[0] in backslash:
                    struct.pack_into('>H', d, cstart + i + 1, i_str)   # ldc_w
                    patched += 1
                elif op == 0x12 and code[i + 1] in backslash:
                    d[cstart + i + 1] = i_str                          # ldc (needs index < 256)
                    patched += 1
                i += oplen(code, i)
    if patched != 1:
        sys.exit(f'expected exactly one backslash load in toXMLString(String), found {patched}')
    open(out, 'wb').write(bytes(d))
    print(f'repointed {patched} separator constant in toXMLString(String); '
          f'constant pool {cp_count} -> {nxt}')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
