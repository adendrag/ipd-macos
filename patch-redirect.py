#!/usr/bin/env python3
"""Redirect method calls inside one method of a class file to a static helper.

    patch-redirect.py <in.class> <out.class> <scope-method> <scope-desc> \
        <owner> <name> <desc> <helper-class> <helper-desc> <expected-count>

Every invokevirtual/invokestatic of <owner>.<name><desc> inside
<scope-method><scope-desc> becomes `invokestatic <helper-class>.<name><helper-desc>`.
For invokevirtual the helper takes the receiver as its first parameter, so the
operand stack is consumed identically; invokevirtual and invokestatic are both
3-byte instructions, so no offsets or stack map frames move. New constant-pool
entries are appended; nothing existing is mutated. Fails unless exactly
<expected-count> call sites were rewritten.

Used by build-ipd-macos.sh for the dark-mode (Application.start) and
save-name (FileSelectionDialog.getSelectionHelper) fixes.
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


def main(src, dst, scope, scope_desc, owner, name, desc, helper, helper_desc, expected):
    d = bytearray(open(src, 'rb').read())
    e, cp_count, cp_end = parse_cp(d)

    targets = set()
    for i, (t, v) in e.items():
        if t != 10:
            continue
        ci, nti = v
        nt = e[nti][1]
        if (utf8(e, e[ci][1]) == owner and utf8(e, nt[0]) == name
                and utf8(e, nt[1]) == desc):
            targets.add(i)
    if not targets:
        sys.exit(f'{owner}.{name}{desc} not referenced -- already patched?')

    add, nxt = bytearray(), cp_count

    def u(s):
        nonlocal nxt
        b = s.encode(); add.extend(b'\x01' + struct.pack('>H', len(b)) + b)
        nxt += 1; return nxt - 1

    i_cls = u(helper)
    add.extend(b'\x07' + struct.pack('>H', i_cls)); i_class = nxt; nxt += 1
    i_name = u(name); i_desc = u(helper_desc)
    add.extend(b'\x0c' + struct.pack('>HH', i_name, i_desc)); i_nt = nxt; nxt += 1
    add.extend(b'\x0a' + struct.pack('>HH', i_class, i_nt)); i_ref = nxt; nxt += 1

    d[8:10] = struct.pack('>H', nxt)
    d[cp_end:cp_end] = add

    p = cp_end + len(add) + 6
    p += 2 + 2 * struct.unpack_from('>H', d, p)[0]
    p, _ = members(d, p)
    p, methods = members(d, p)

    patched = 0
    for ni, di, attrs in methods:
        if utf8(e, ni) != scope or utf8(e, di) != scope_desc:
            continue
        for an, aoff, al in attrs:
            if utf8(e, an) != 'Code':
                continue
            clen = struct.unpack_from('>I', d, aoff + 4)[0]
            cs = aoff + 8
            code = d[cs:cs + clen]
            i = 0
            while i < len(code):
                if code[i] in (0xb6, 0xb8) and struct.unpack_from('>H', code, i + 1)[0] in targets:
                    d[cs + i] = 0xb8
                    struct.pack_into('>H', d, cs + i + 1, i_ref)
                    patched += 1
                i += oplen(code, i)
    if patched != expected:
        sys.exit(f'expected {expected} {owner}.{name} call(s) in {scope}, found {patched}')
    open(dst, 'wb').write(bytes(d))
    print(f'{scope}: redirected {patched} {name} -> {helper.rsplit("/", 1)[-1]}; '
          f'constant pool {cp_count} -> {nxt}')


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) != 10:
        sys.exit(__doc__)
    main(*a[:9], int(a[9]))
