#!/usr/bin/env python3
# A Unity game's BC textures re-encoded as ASTC, so the app runs on GPUs without BC formats (iPhones before the A17 Pro): a RomFS image (dm/tools/romfs_image.py) → another image whose
# UnityFS bundles hold their Texture2D objects in ASTC. Unity's console player samples ASTC natively (Tegra X1 has it, and the host maps NVN's ASTC formats to Metal's), and every Apple
# GPU since the A8 reads ASTC, so the game itself then asks for ASTC textures: no work at run time, and no decoded copies in memory.
# Block sizes keep memory at or below the BC size (the presets; bits per texel: DXT1 / BC4 4, DXT5 / BC5 / BC7 8, ASTC 4x4 8, 5x5 5.12, 6x6 3.56):
#   lean (default)  DXT1, BC4, DXT5 → 6x6; BC5, BC7 → 5x5      (Pokémon Brilliant Diamond already keeps a third of its textures in ASTC 6x6)
#   balanced        DXT1, BC4 → 6x6; DXT5, BC5, BC7 → 5x5
#   same            DXT1, BC4 → 6x6; DXT5, BC5, BC7 → 4x4
# Each mip level is decoded (texture2ddecoder) and encoded on its own (Arm's astcenc through astc-encoder-py), in sRGB when the texture is (m_ColorSpace 1). The data goes inline into
# the object (UnityPy writes the bundle again, LZ4). Left as they are, and counted: textures of more than one image (cubemaps, arrays), Crunch-compressed ones, and BC data whose
# size does not match its mip chain; files that are not UnityFS bundles (the player's own .assets) are copied unchanged.
# Usage: astc_textures.py <in image> <out image> [--preset lean|balanced|same] [--quality fast|medium] [--jobs N] [--limit N] [--match TEXT]
#   needs: pip install UnityPy texture2ddecoder (UnityPy brings astc-encoder-py)
import argparse, collections, concurrent.futures as cf, os, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'dm/tools'))
import romfs_image

DXT1, DXT5, BC4, BC5, BC6H, BC7 = 10, 12, 26, 27, 24, 25
ASTC = {4: 48, 5: 49, 6: 50}   # Unity 2019.4 TextureFormat: ASTC_4x4, ASTC_5x5, ASTC_6x6
BLOCK_BYTES = {DXT1: 8, BC4: 8, DXT5: 16, BC5: 16, BC7: 16}
PRESETS = {'lean': {DXT1: 6, BC4: 6, DXT5: 6, BC5: 5, BC7: 5},
           'balanced': {DXT1: 6, BC4: 6, DXT5: 5, BC5: 5, BC7: 5},
           'same': {DXT1: 6, BC4: 6, DXT5: 4, BC5: 4, BC7: 4}}


def levels(w, h, mips):
    out = []
    for i in range(mips):
        out.append((max(1, w >> i), max(1, h >> i)))
    return out


def decode(fmt, data, w, h):
    """RGBA bytes of one level, w x h (BC decoders work on whole 4x4 blocks: decoded padded, then cropped)"""
    import texture2ddecoder as T
    pw, ph = (w + 3) & ~3, (h + 3) & ~3
    f = {DXT1: T.decode_bc1, DXT5: T.decode_bc3, BC4: T.decode_bc4, BC5: T.decode_bc5, BC7: T.decode_bc7}[fmt]
    bgra = f(data, pw, ph)
    if (pw, ph) != (w, h): bgra = b''.join(bgra[y * pw * 4:y * pw * 4 + w * 4] for y in range(h))
    return bgra


_ctx = {}
def encode(bgra, w, h, block, srgb, quality):
    import astc_encoder as A
    key = (block, srgb, quality)
    if key not in _ctx:
        q = A.ASTCQualityPreset.FAST if quality == 'fast' else A.ASTCQualityPreset.MEDIUM
        _ctx[key] = A.ASTCContext(A.ASTCConfig(A.ASTCProfile.LDR_SRGB if srgb else A.ASTCProfile.LDR, block, block, 1, q))
    img = A.ASTCImage(A.ASTCType.U8, w, h, 1, bgra)
    return _ctx[key].compress(img, A.ASTCSwizzle.from_str('bgra'))   # texture2ddecoder gives BGRA


def convert_texture(t, st, preset, quality, freed=None):
    """t (a UnityPy Texture2D) re-encoded in place when it is BC; returns whether it changed. freed: a list that gets (stream file name, offset, size) of the BC bytes the texture no longer uses"""
    fmt = int(t.m_TextureFormat)
    crunched = fmt in (28, 29)   # DXT1Crunched / DXT5Crunched: Unity unpacks them to DXT1 / DXT5 when it loads them, so they are BC on the GPU too
    if fmt not in BLOCK_BYTES and not crunched:
        if fmt == BC6H: st['BC6H, left'] += 1
        return False
    if getattr(t, 'm_ImageCount', 1) != 1: st['several images, left'] += 1; return False
    raw = bytes(t.get_image_data()); w, h, mips = t.m_Width, t.m_Height, max(1, t.m_MipCount)   # from the object or its .resS stream
    if crunched:   # the first level, unpacked (texture2ddecoder); the converted texture keeps that level only
        import texture2ddecoder as T
        try: raw = bytes(T.unpack_unity_crunch(raw))
        except Exception: st['crunched, unreadable, left'] += 1; return False
        fmt, mips = (DXT1 if fmt == 28 else DXT5), 1
        lw0 = ((w + 3) // 4) * ((h + 3) // 4) * BLOCK_BYTES[fmt]
        if len(raw) < lw0: st['crunched, short, left'] += 1; return False
        raw = raw[:lw0]; t.m_MipCount = 1
    lv = levels(w, h, mips); bb = BLOCK_BYTES[fmt]
    sizes = [((lw + 3) // 4) * ((lh + 3) // 4) * bb for lw, lh in lv]
    if sum(sizes) != len(raw): st['size mismatch, left'] += 1; return False
    block, srgb = PRESETS[preset][fmt], getattr(t, 'm_ColorSpace', 0) == 1
    out, off = [], 0
    for (lw, lh), sz in zip(lv, sizes):
        out.append(encode(decode(fmt, raw[off:off + sz], lw, lh), lw, lh, block, srgb, quality)); off += sz
    new = b''.join(out)
    t.m_TextureFormat = ASTC[block]
    t.image_data = new
    t.m_CompleteImageSize = len(new)
    if t.m_StreamData and t.m_StreamData.size:
        if freed is not None: freed.append((t.m_StreamData.path.rsplit('/', 1)[-1], int(t.m_StreamData.offset), int(t.m_StreamData.size)))
        t.m_StreamData.offset, t.m_StreamData.size, t.m_StreamData.path = 0, 0, ''
    t.save()
    st[f'{fmt}{" (crunched)" if crunched else ""}→ASTC{block}x{block}'] += 1; st['bytes before'] += len(raw); st['bytes after'] += len(new)
    return True


def convert_bundle(args):
    """(path, new bytes or None, Counter of what happened)"""
    path, data, preset, quality = args
    import UnityPy
    st = collections.Counter()
    try: env = UnityPy.load(data)
    except Exception: st['bundle unreadable'] += 1; return path, None, st
    changed, freed = False, []
    for obj in env.objects:
        if obj.type.name != 'Texture2D': continue
        try: t = obj.read()
        except Exception: st['texture unreadable'] += 1; continue
        changed |= convert_texture(t, st, preset, quality, freed)
    if not changed: return path, None, st
    # The converted textures' data is now inline; their old BC bytes in the .resS stream are zeroed, which LZ4HC packs to almost nothing (the stream keeps its size, so the
    # offsets of what else it holds, meshes and textures left as they were, stay valid)
    from UnityPy.streams import EndianBinaryReader
    for name in {n for n, _, _ in freed}:
        fobj = env.file.files.get(name)
        if fobj is None: st['stream not found'] += 1; continue
        buf = bytearray(fobj.bytes)
        for n, off, size in freed:
            if n == name and off + size <= len(buf): buf[off:off + size] = bytes(size)
        new = EndianBinaryReader(bytes(buf))
        for attr in ('flags', 'name', 'path'):   # the bundle's node attributes the writer needs
            if hasattr(fobj, attr): setattr(new, attr, getattr(fobj, attr))
        env.file.files[name] = new
    try: return path, env.file.save(packer='lz4hc'), st   # LZ4HC, as the game's own bundles: smaller files, the same fast decompression
    except Exception as e: st[f'save failed'] += 1; return path, None, st


def main():
    ap = argparse.ArgumentParser(description='re-encode a Unity game\'s BC textures as ASTC in a RomFS image')
    ap.add_argument('src'); ap.add_argument('dst')
    ap.add_argument('--preset', choices=PRESETS, default='lean'); ap.add_argument('--quality', choices=('fast', 'medium'), default='fast')
    ap.add_argument('--jobs', type=int, default=os.cpu_count()); ap.add_argument('--limit', type=int, default=0); ap.add_argument('--match', default='')
    a = ap.parse_args()
    idx = romfs_image.read_index(a.src)
    files = [(p, o, s) for p, (d, o, s) in idx.items() if not d]
    with open(a.src, 'rb') as f:
        def bundles():
            n = 0
            for p, o, s in files:
                if a.match and a.match not in p: continue
                f.seek(o); head = f.read(8)
                if head != b'UnityFS\0': continue
                f.seek(o); yield (p, f.read(s), a.preset, a.quality); n += 1
                if a.limit and n >= a.limit: return
        t0 = time.time(); new, total, done = {}, collections.Counter(), 0
        with cf.ProcessPoolExecutor(a.jobs) as ex:
            for path, data, st in ex.map(convert_bundle, bundles(), chunksize=4):
                total.update(st); done += 1
                if data is not None: new[path] = data
                if done % 500 == 0: print(f'  {done} bundles, {len(new)} rewritten, {time.time() - t0:.0f} s', flush=True)
    print(f'{done} bundles read, {len(new)} rewritten in {time.time() - t0:.0f} s')
    # the player's own serialized files outside the bundles (Data/resources.assets, Data/Resources/unity default resources, ...): loaded together, so a texture finds its .resS
    import tempfile, UnityPy
    loose = [p for p, o, s in files if p.startswith('Data/') and not p.startswith('Data/StreamingAssets/') and '/Managed/' not in p]
    with tempfile.TemporaryDirectory() as tmp, open(a.src, 'rb') as f2:
        for p in loose:
            _, o, s = idx[p]; f2.seek(o); dst = os.path.join(tmp, p[5:]); os.makedirs(os.path.dirname(dst), exist_ok=True); open(dst, 'wb').write(f2.read(s))
        env = UnityPy.load(tmp); touched = set()
        for obj in env.objects:
            if obj.type.name != 'Texture2D': continue
            try: t = obj.read()
            except Exception: total['texture unreadable'] += 1; continue
            if convert_texture(t, total, a.preset, a.quality): touched.add(obj.assets_file)
        for af in touched:
            name = af.name
            match = [p for p in loose if p.rsplit('/', 1)[-1] == name]
            if len(match) != 1: total['loose file not placed'] += 1; continue
            new[match[0]] = af.save(); print(f'  {match[0]}: textures converted')
    for k, v in sorted(total.items()):
        if not k.startswith('bytes'): print(f'  {k}: {v}')
    if total['bytes before']: print(f'  texture data {total["bytes before"] / 1e6:.0f} MB → {total["bytes after"] / 1e6:.0f} MB ({100 * total["bytes after"] / total["bytes before"]:.0f}%)')
    # the output image: the same tree, the rewritten bundles in place of the old ones
    kids = {'': []}
    for path, (d, off, size) in idx.items():
        kids.setdefault(path.rsplit('/', 1)[0] if '/' in path else '', []).append(path)
        if d: kids.setdefault(path, [])
    ents = [[b'', '', True, 0, 0]]; i = 0
    while i < len(ents):
        name, path, isdir, _, _ = ents[i]
        if isdir:
            ch = sorted(kids.get(path, ()), key=lambda c: c.rsplit('/', 1)[-1].encode())
            ents[i][3], ents[i][4] = len(ents), len(ch)
            ents.extend([c.rsplit('/', 1)[-1].encode(), c, idx[c][0], 0, 0] for c in ch)
        i += 1
    part = a.dst + '.part'
    with open(a.src, 'rb') as inp, open(part, 'wb') as out:
        out.write(b'\0' * romfs_image.HEAD.size); pos = romfs_image.HEAD.size
        for e in ents:
            if e[2]: continue
            if e[1] in new: out.write(new[e[1]]); size = len(new[e[1]])
            else:
                _, off, size = idx[e[1]]; inp.seek(off); left = size
                while left: b = inp.read(min(left, 8 << 20)); out.write(b); left -= len(b)
            e[3], e[4] = pos, size; pos += size
        head, index = romfs_image.layout(ents, pos)
        out.write(index); out.seek(0); out.write(head)
    os.replace(part, a.dst)
    print(f'done: {a.dst} ({os.path.getsize(a.dst) / 1e9:.2f} GB)')


if __name__ == '__main__':
    main()
