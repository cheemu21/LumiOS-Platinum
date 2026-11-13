#!/usr/bin/env python3
# The names the cheats panel's "Add a Pokémon" form lists (DmCheats.m), read from the game's own message tables at build time (Pokémon Brilliant Diamond / Luminescent Platinum:
# Data/StreamingAssets/AssetAssistant/Message/common_msbt and english): species (english_ss_monsname, index = species number), items (english_ss_itemname, index = item number;
# the balls are items 1 to 16, whose numbers are the ball IDs), natures (english_ss_seikaku) and abilities (english_ss_tokusei). Nothing of the game is in the repository: the app
# gets them from the player's own files. Writes JSON {"species": [...], "items": [...], "natures": [...], "abilities": [...]}.
# Usage: pkx_names.py <RomFS image> <out.json> [language]   (needs UnityPy; without it, or without the tables, exit 2 and the form shows numbers)
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import romfs_image

TABLES = {'species': 'ss_monsname', 'items': 'ss_itemname', 'natures': 'ss_seikaku', 'abilities': 'ss_tokusei'}


def words(entry):
    return ''.join(w.get('str', '') for w in entry.get('wordDataArray', []))


def main():
    if len(sys.argv) < 3: sys.exit('usage: pkx_names.py <RomFS image> <out.json> [language]')
    img, out, lang = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else 'english')
    try: import UnityPy
    except ImportError: print('pkx_names.py: UnityPy is not installed (pip install UnityPy): the form shows numbers'); sys.exit(2)
    idx = romfs_image.read_index(img)
    want = {f'{lang}_{t}': k for k, t in TABLES.items()}
    got = {}
    with open(img, 'rb') as f:
        for p, (d, o, s) in idx.items():
            if d or '/AssetAssistant/Message/' not in p: continue
            f.seek(o)
            try: env = UnityPy.load(f.read(s))
            except Exception: continue
            for obj in env.objects:
                if obj.type.name != 'MonoBehaviour': continue
                try: t = obj.read_typetree()
                except Exception: continue
                k = want.get(t.get('m_Name', ''))
                if k and k not in got:
                    labels = t.get('labelDataArray', [])
                    names = [''] * (max((e.get('arrayIndex', i) for i, e in enumerate(labels)), default=-1) + 1)
                    for i, e in enumerate(labels): names[e.get('arrayIndex', i)] = words(e)
                    got[k] = names
    if 'species' not in got: print(f'pkx_names.py: no {lang}_ss_monsname table in {img}: the form shows numbers'); sys.exit(2)
    Path(out).write_text(json.dumps(got, ensure_ascii=False))
    print(f'pkx_names.py: {", ".join(f"{len(v)} {k}" for k, v in got.items())} → {out}')


if __name__ == '__main__':
    main()
