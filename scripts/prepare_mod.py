#!/usr/bin/env python3
# A game with an Atmosphère-layout mod (exefs/ and romfs/, as Luminescent Platinum ships for Pokémon Brilliant Diamond 1.3.0) → a build folder whose extraction is the modded game,
# which build_ipa_from_nsp.py then builds like any other (--work-dir <out>: it reuses an extraction it finds, so the steps after it see the mod's code and files).
#   exefs/<main build ID>.ips (IPS32 or IPS) is applied to main as Atmosphère's loader does (offsets count from the NSO header, 0x100 before the image); main keeps its build ID, so the profile's
#     rows still match it. main is written uncompressed with its hash-check flags cleared (dm/tools/nso.py does not check a modified main, as Horizon does not).
#   exefs/subsdk<n> (a code module the mod adds, an exlaunch-style plugin linked against main at Horizon's module layout) is added beside the game's modules. The profile lists it in modules
#     and places it with module_at (loader.c), so its fixed distance to main holds.
#   exefs/main, exefs/main.npdm or an exefs/sdk replacing the game's own is refused: nothing here checks such a module against the profile.
#   romfs/ is laid over the game's RomFS: the image (dm/tools/romfs_image.py) is an APFS clone of the game's, its file data shared, with the mod's files appended after it and a new index
#     naming them in place of the files they replace, so the modded image costs the mod's size on disk, not the game's.
# Usage: prepare_mod.py <game build folder> <mod folder> <out build folder> [--version v393216]   (the game build folder is one build_ipa_from_nsp.py made from the NSPs: <id>_build)
import argparse, os, shutil, struct, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import nso, romfs_image


class Error(Exception): pass


def clone(src, dst):   # an APFS clone on the same volume, else a copy
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink(): dst.unlink()
    if subprocess.run(['cp', '-c', str(src), str(dst)], capture_output=True).returncode != 0: shutil.copy2(src, dst)


def clone_tree(src, dst):
    if dst.exists(): shutil.rmtree(dst)
    if subprocess.run(['cp', '-cR', str(src), str(dst)], capture_output=True).returncode != 0: shutil.copytree(src, dst)


def ips_records(data):
    """[(offset, bytes)] of an IPS or IPS32 patch; an RLE record becomes its run"""
    if data[:5] == b'PATCH': wide, p, end = False, 5, b'EOF'
    elif data[:5] == b'IPS32': wide, p, end = True, 5, b'EEOF'
    else: raise Error('not an IPS / IPS32 patch')
    out = []
    while data[p:p + len(end)] != end:
        if p + (4 if wide else 3) + 2 > len(data): raise Error('IPS patch cut short')
        off = int.from_bytes(data[p:p + (4 if wide else 3)], 'big'); p += 4 if wide else 3
        n = int.from_bytes(data[p:p + 2], 'big'); p += 2
        if n == 0:
            run = int.from_bytes(data[p:p + 2], 'big'); out.append((off, bytes([data[p + 2]]) * run)); p += 3
        else:
            out.append((off, data[p:p + n])); p += n
    return out


def nso_header(path):
    d = Path(path).read_bytes()
    if d[:4] != b'NSO0': raise Error(f'{path}: not an NSO')
    return d


def patched_main(src, ips, dst):
    """main with the IPS applied, written as an uncompressed NSO with the same header (build ID, module name, segment layout) and no hash checks"""
    raw = nso_header(src); m = nso.load(raw, 'main')
    image = bytearray(m.image)
    for off, b in ips_records(ips.read_bytes()):
        at = off - 0x100   # Atmosphère: patch offsets count from the start of the NSO file's header
        if at < 0 or at + len(b) > len(image): raise Error(f'{ips.name}: a record at {off:#x} (+{len(b)}) is outside main\'s image ({len(image):#x} bytes)')
        image[at:at + len(b)] = b
    h = bytearray(raw[:0x100])
    struct.pack_into('<I', h, 0xC, 0)   # no compression, no hash checks
    segs = [struct.unpack_from('<IIII', h, 0x10 + i * 0x10) for i in range(3)]
    body = bytearray()
    for i, (_, moff, size, last) in enumerate(segs):
        struct.pack_into('<IIII', h, 0x10 + i * 0x10, 0x100 + moff, moff, size, last)   # file offset = 0x100 + memory offset: the gaps between segments are written as they are in memory
        struct.pack_into('<I', h, 0x60 + i * 4, size)
    end = max(moff + size for _, moff, size, _ in segs)
    body = bytes(image[:end]) + bytes(max(0, end - len(image)))
    h[0xA0:0x100] = bytes(0x60)   # segment hashes: unused with the flags cleared
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + '.part'); tmp.write_bytes(bytes(h) + body); os.replace(tmp, dst)
    return len(ips_records(ips.read_bytes()))


def _lz4_block(src, start, want):
    """One LZ4 block read from src[start:] that ends, on a literal run, exactly at want bytes of output: (end position, output) or None. A pure decoder, so the block's
    length need not be known (lz4.block needs it)"""
    i, out = start, bytearray()
    while i < len(src):
        t = src[i]; i += 1; ll = t >> 4
        if ll == 15:
            while True:
                b = src[i]; i += 1; ll += b
                if b != 255: break
        out += src[i:i + ll]; i += ll
        if len(out) == want: return i, out
        if len(out) > want or i + 2 > len(src): return None
        off = src[i] | src[i + 1] << 8; i += 2; ml = t & 15
        if ml == 15:
            while True:
                b = src[i]; i += 1; ml += b
                if b != 255: break
        ml += 4
        if off == 0 or off > len(out) or len(out) + ml > want: return None
        for _ in range(ml): out.append(out[-off])
    return None


def repair_unityfs(data):
    """data with its block table repaired, or None when it needs none (or is no LZ4 UnityFS bundle, or cannot be repaired).
    Luminescent Platinum 2.2F ships pokemons/common/pm0487_12_00 (a Giratina form, a 2022 file in a 2025 release) with the compressed sizes of its first two blocks 302 and 363
    bytes too large and 665 bytes of padding after the blocks: read by the table, block 1 starts inside block 0's tail and fails on any LZ4 reader (Unity's too). The blocks
    themselves are whole: read back to back, each ends exactly at its 128 KB, and the bundle is then exactly the size its header declares. The repair keeps every compressed byte
    and writes the table with the lengths the blocks have"""
    import lz4.block as L
    if data[:8] != b'UnityFS\0': return None
    p = 8; ver = struct.unpack_from('>I', data, p)[0]; p += 4
    for _ in range(2): p = data.index(b'\0', p) + 1
    size, csz, usz, flags = struct.unpack_from('>QIII', data, p); hp = p; p += 20
    if ver >= 7: p = (p + 15) & ~15
    if not flags & 0x80 or flags & 0x3f not in (2, 3): return None   # only the layout seen: the table at the end, LZ4
    try: info = bytearray(L.decompress(data[len(data) - csz:], uncompressed_size=usz))
    except Exception: return None
    nb = struct.unpack_from('>I', info, 16)[0]
    blocks = [list(struct.unpack_from('>IIH', info, 20 + k * 10)) for k in range(nb)]
    if any(f & 0x3f not in (2, 3) for _, _, f in blocks): return None
    o, ok = p, True
    for u, c, _ in blocks:
        try: L.decompress(data[o:o + c], uncompressed_size=u)
        except Exception: ok = False; break
        o += c
    if ok: return None   # the table reads: nothing to repair
    src, pos = data[p:len(data) - csz], 0
    for b in blocks:
        r = _lz4_block(src, pos, b[0])
        if not r: return None
        b[1] = r[0] - pos; pos = r[0]
    for k, (u, c, f) in enumerate(blocks): struct.pack_into('>IIH', info, 20 + k * 10, u, c, f)
    packed = L.compress(bytes(info), mode='high_compression', store_size=False)
    head = bytearray(data[:p])
    out_len = p + pos + len(packed)
    struct.pack_into('>QIII', head, hp, out_len, len(packed), len(info), flags)
    return bytes(head) + src[:pos] + packed


def overlay_image(base, folder, dst):
    """dst: base's RomFS image with folder's files laid over it (added, or in place of a file of the same path); the base's data is shared through an APFS clone"""
    idx = romfs_image.read_index(str(base))
    over = {}
    for root, dirs, files in os.walk(folder):
        dirs.sort()
        for f in sorted(files):
            if f.encode() in romfs_image.ARTIFACTS or f == '.DS_Store': continue
            p = os.path.join(root, f); rel = os.path.relpath(p, folder).replace(os.sep, '/')
            if idx.get(rel, (False,))[0]: raise Error(f'{rel}: a file in the mod, a folder in the game')
            over[rel] = p
    clone(base, dst)
    with open(dst, 'r+b') as out:
        magic, ioff, isz, n = romfs_image.HEAD.unpack(out.read(romfs_image.HEAD.size))
        if magic != romfs_image.MAGIC: raise Error(f'{base}: not a RomFS image')
        out.seek(0, 2); pos = out.tell()
        files = {p: (off, size) for p, (d, off, size) in idx.items() if not d}
        added = replaced = 0
        for rel, p in sorted(over.items()):   # the mod's files after the base's index; the old index stays as unused bytes
            replaced += rel in files; added += rel not in files
            fixed = repair_unityfs(Path(p).read_bytes()) if os.path.getsize(p) < 64 << 20 and open(p, 'rb').read(8) == b'UnityFS\0' else None
            if fixed is not None:
                out.write(fixed); size = len(fixed); print(f'{rel}: block table repaired ({os.path.getsize(p)} → {size} bytes; the mod\'s file is left as it is)')
            else: size = romfs_image.copy_file(p, out)
            files[rel] = (pos, size); pos += size
        # the tree: every directory of the base and of the mod, breadth-first, children sorted by name bytes (romfs_image.entries' order)
        kids = {'': set()}
        for rel in files:
            parts = rel.split('/')
            for k in range(1, len(parts) + 1):
                parent, path = '/'.join(parts[:k - 1]), '/'.join(parts[:k])
                kids.setdefault(parent, set()).add(path)
                if k < len(parts): kids.setdefault(path, set())
        ents = [[b'', '', True, 0, 0]]; i = 0
        while i < len(ents):
            name, path, isdir, _, _ = ents[i]
            if isdir:
                ch = sorted(kids.get(path, ()), key=lambda c: c.rsplit('/', 1)[-1].encode())
                ents[i][3], ents[i][4] = len(ents), len(ch)
                for c in ch:
                    d = c in kids
                    ents.append([c.rsplit('/', 1)[-1].encode(), c, d, 0 if d else files[c][0], 0 if d else files[c][1]])
            i += 1
        head, index = romfs_image.layout(ents, pos)
        out.write(index); out.seek(0); out.write(head)
    return added, replaced


def compact_image(src, dst):
    """dst: src's files only, in the same tree order (romfs_image's layout), without the bytes the mod's files replaced: an image to ship (the IPA carries every byte of the
    image it gets). Returns (old size, new size)"""
    idx = romfs_image.read_index(str(src))
    kids = {'': []}
    for path, (d, off, size) in idx.items():
        parent = path.rsplit('/', 1)[0] if '/' in path else ''
        kids.setdefault(parent, []).append(path)
        if d: kids.setdefault(path, [])
    ents = [[b'', '', True, 0, 0]]; i = 0
    while i < len(ents):
        name, path, isdir, _, _ = ents[i]
        if isdir:
            ch = sorted(kids.get(path, ()), key=lambda c: c.rsplit('/', 1)[-1].encode())
            ents[i][3], ents[i][4] = len(ents), len(ch)
            ents.extend([c.rsplit('/', 1)[-1].encode(), c, idx[c][0], 0, 0] for c in ch)
        i += 1
    part = Path(str(dst) + '.part')
    with open(src, 'rb') as inp, open(part, 'wb') as out:
        out.write(b'\0' * romfs_image.HEAD.size); pos = romfs_image.HEAD.size
        for e in ents:
            if e[2]: continue
            _, off, size = idx[e[1]]; inp.seek(off); left = size
            while left: b = inp.read(min(left, 8 << 20)); out.write(b); left -= len(b)
            e[3], e[4] = pos, size; pos += size
        head, index = romfs_image.layout(ents, pos)
        out.write(index); out.seek(0); out.write(head)
    old = os.path.getsize(src); os.replace(part, dst)
    return old, os.path.getsize(dst)


def main():
    ap = argparse.ArgumentParser(description=__doc__ if False else 'lay a mod (exefs/, romfs/) over an extracted game, for build_ipa_from_nsp.py --work-dir')
    ap.add_argument('game'); ap.add_argument('mod'); ap.add_argument('out'); ap.add_argument('--version', default='')
    ap.add_argument('--compact', action='store_true', help='write the RomFS image without the replaced files\' bytes (a full copy: for the IPA; the default clone shares the game\'s data)')
    a = ap.parse_args()
    game, mod, out = Path(a.game), Path(a.mod), Path(a.out)
    vers = sorted(p.name for p in (game / 'extract').iterdir() if p.is_dir() and p.name.startswith('v') and not p.name.endswith('.partial'))
    ver = a.version or (vers[-1] if vers else '')
    src = game / 'extract' / ver
    if not (src / 'ExeFS' / 'main').exists() or not (src / 'RomFS.img').is_file(): raise Error(f'{src}: no extracted ExeFS / RomFS.img (run build_ipa_from_nsp.py on the NSPs first)')
    dst = out / 'extract' / ver
    exe = mod / 'exefs'
    for bad in ('main', 'main.npdm', 'sdk', 'rtld'):
        if (exe / bad).exists(): raise Error(f'{exe / bad}: the mod replaces the game\'s {bad}; only IPS patches to main and added subsdk modules are supported')
    bid = nso.load(nso_header(src / 'ExeFS' / 'main'), 'main').build_id[:16].hex().upper()   # Atmosphère names a patch by the first 0x10 bytes of the build ID
    ips = [p for p in exe.glob('*.ips') if p.stem.upper()[:32] == bid.upper()[:32]] if exe.is_dir() else []
    others = [p for p in exe.glob('*.ips') if p not in ips] if exe.is_dir() else []
    if others: raise Error(f'{", ".join(p.name for p in others)}: IPS patches for another build than main {bid[:32]}')
    # ExeFS: the game's modules as clones, main patched, the mod's added modules
    for f in (src / 'ExeFS').iterdir():
        if f.is_file() and not (f.name == 'main' and ips): clone(f, dst / 'ExeFS' / f.name)
    if ips: print(f'main: {patched_main(src / "ExeFS" / "main", ips[0], dst / "ExeFS" / "main")} IPS records from {ips[0].name}')
    for f in sorted(exe.glob('subsdk*')) if exe.is_dir() else []:
        if (src / 'ExeFS' / f.name).exists(): raise Error(f'{f.name}: the game has a module of that name; a mod may only add one')
        nso.load(nso_header(f), f.name); clone(f, dst / 'ExeFS' / f.name); print(f'{f.name}: added')
    # the other extracted files (control data, icon, the HTML manual) as clones
    for f in src.iterdir():
        if f.name in ('ExeFS', 'RomFS.img') or f.name.startswith('RomFS.img.'): continue
        (clone_tree if f.is_dir() else clone)(f, dst / f.name)
    if (mod / 'romfs').is_dir():
        added, replaced = overlay_image(src / 'RomFS.img', mod / 'romfs', dst / 'RomFS.img')
        print(f'RomFS: {replaced} files replaced, {added} added from {mod / "romfs"}')
        if a.compact:
            old, new = compact_image(dst / 'RomFS.img', dst / 'RomFS.img'); print(f'RomFS image compacted: {old / 1e9:.2f} → {new / 1e9:.2f} GB')
    else: clone(src / 'RomFS.img', dst / 'RomFS.img')
    # the logs nx_extract left (their sizes are the progress estimate of a later extraction) are not needed: the extraction is reused as it is
    print(f'done: {dst}')


if __name__ == '__main__':
    try: main()
    except (Error, nso.Error, OSError) as e: sys.exit(f'prepare_mod.py: {e}')
