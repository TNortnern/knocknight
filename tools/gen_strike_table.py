"""Merge docs/gameplay-spec.md section 3.3 timing table with data/strikes.json -> data/strike_table.json"""
import json, re
spec = open('docs/gameplay-spec.md', encoding='utf-8').read().splitlines()
strikes = json.load(open('data/strikes.json'))
rows = {}
for ln in spec:
    m = re.match(r'\|\s*(\d+)\s*\|\s*(\w+)\s*\|\s*(.+?)\s*\|\s*(\w+)\s*\|\s*(\w)\s*\|\s*([\d.]+)/([\d.]+)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)-([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|', ln)
    if not m:
        continue
    g = m.groups()
    rows[g[1]] = dict(index=int(g[0]), clip=g[2], zone=g[3], dir=g[4], damage=float(g[5]), block_damage=float(g[6]),
                      stamina=float(g[7]), action=float(g[8]), c0=float(g[9]), c1=float(g[10]),
                      recoil=float(g[11]), chain=float(g[12]), reach=float(g[13]))
out = {}
for s in strikes:
    r = rows[s['tag']]
    assert r['clip'] == s['clip'], (r['clip'], s['clip'])
    tag = s['tag']
    rec = dict(r)
    rec['tag'] = tag
    rec['source'] = s['source']
    rec['limb'] = tag[0]  # L / R
    rec['power'] = ('P' in tag[1:3] and tag[1] == 'P') or 'OverHand' in tag or 'BackFist' in tag
    out[tag] = rec
assert len(out) == 74, len(out)
json.dump(out, open('data/strike_table.json', 'w'), indent=1)
print('wrote', len(out))
