#!/usr/bin/env python3
"""Writes data/punch_variants.json: per-strike punch variants layered on data/strike_table.json rows.
Each variant overrides clip / action time / contact floor and carries multipliers relative to its base strike
(damage `dmg`, stamina `sta`), a step (`lunge` m, `lunge_t` s; negative = pull back), procedural pose amounts
(`yaw` deg extra torso turn, `dip` wind-up dip 0..1, `hang` s the arm stays out after contact, `miss_tail` s extra
recovery on a whiff, `miss_lean` / `miss_yaw` overextension) and `reach` (CPU range estimate).
`range` ([lo, hi] centre gap where the variant lands on an idle foe) is written by tools/scan_variants.gd and
preserved here. Run: python tools/gen_punch_variants.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "data", "punch_variants.json")
old = {}
if os.path.exists(OUT):
    old = json.load(open(OUT))

V = {}

def add(base, klass, suffix, clip, **kw):
    key = "%s~%s%s" % (base, klass, suffix)
    row = {"base": base, "class": klass, "clip": clip}
    row.update(kw)
    if key in old and "range" in old[key]:
        row["range"] = old[key]["range"]
    V[key] = row

for side in ("L", "R"):
    # ---- jab / cross (head)
    j = side + "Jab"
    std_clip = "%s J" % side
    pow_clip = "%s J P" % side
    add(j, "flick", "", std_clip, action=0.46, pf=0.17, dmg=0.70, sta=0.70, lunge=0.0, lunge_t=0.2, yaw=-3.0, reach=0.88, chain=0.24, recoil=0.16, hang=0.0, miss_tail=0.0)
    add(j, "flick", "2", "KB_p_Jab_%s_1" % side, action=0.48, pf=0.18, dmg=0.70, sta=0.70, lunge=0.0, lunge_t=0.2, yaw=3.0, reach=0.88, chain=0.25, recoil=0.17, hang=0.0, miss_tail=0.0)
    add(j, "pull", "2", "KB_p_Jab_%s_1" % side, action=0.54, pf=0.21, dmg=0.85, sta=0.90, lunge=-0.12, lunge_t=0.22, yaw=2.0, reach=0.85, chain=0.29, recoil=0.19, miss_tail=0.0)
    add(j, "std", "2", "KB_p_Jab_%s_1" % side, action=0.60, dmg=1.0, sta=1.0, reach=0.95, yaw=0.0)
    add(j, "pull", "", std_clip, action=0.52, pf=0.20, dmg=0.85, sta=0.90, lunge=-0.12, lunge_t=0.22, yaw=-2.0, reach=0.85, chain=0.28, recoil=0.18, miss_tail=0.0)
    add(j, "lunge", "", pow_clip, action=0.78, pf=0.34, dmg=1.45, sta=1.5, lunge=0.40, lunge_t=0.26, yaw=6.0, dip=0.5, hang=0.10, miss_tail=0.32, miss_lean=0.55, miss_yaw=14.0, power=True, reach=1.30, chain=0.52, recoil=0.32)
    add(j, "lunge", "2", "KB_m_Jab_%s" % side, action=0.82, pf=0.36, dmg=1.45, sta=1.5, lunge=0.36, lunge_t=0.28, yaw=9.0, dip=0.6, hang=0.12, miss_tail=0.34, miss_lean=0.6, miss_yaw=18.0, power=True, reach=1.26, chain=0.54, recoil=0.34)
    # ---- hook (head)
    h = side + "Hook"
    add(h, "tight", "", "%s H" % side, action=0.62, pf=0.25, dmg=0.85, sta=0.90, lunge=0.10, lunge_t=0.2, yaw=-5.0, reach=0.88, chain=0.40, recoil=0.24, miss_tail=0.0)
    add(h, "tight", "2", "KB_p_Hook_%s" % side, action=0.64, pf=0.26, dmg=0.85, sta=0.90, lunge=0.10, lunge_t=0.2, yaw=5.0, reach=0.88, chain=0.41, recoil=0.25, miss_tail=0.0)
    add(h, "std", "2", "KB_p_Hook_%s" % side, action=0.78, dmg=1.0, sta=1.0, reach=0.98)
    add(h, "wide", "", "%s H P" % side, action=0.94, pf=0.40, dmg=1.4, sta=1.3, lunge=0.42, lunge_t=0.28, yaw=22.0, dip=0.4, hang=0.08, miss_tail=0.38, miss_lean=0.45, miss_yaw=62.0, power=True, reach=1.12, chain=0.62, recoil=0.40)
    add(h, "wide", "2", "KB_m_Hook_%s" % side, action=0.98, pf=0.42, dmg=1.4, sta=1.3, lunge=0.38, lunge_t=0.28, yaw=26.0, dip=0.5, hang=0.08, miss_tail=0.40, miss_lean=0.45, miss_yaw=68.0, power=True, reach=1.10, chain=0.64, recoil=0.42)
    # ---- uppercut (head)
    u = side + "Uppercut"
    add(u, "std", "2", "KB_p_Uppercut_%s" % side, action=0.66, dmg=1.0, sta=1.0, reach=0.88)
    add(u, "rise", "", "%s U P" % side, action=0.86, pf=0.38, dmg=1.4, sta=1.3, lunge=0.22, lunge_t=0.26, yaw=8.0, dip=0.95, hang=0.06, miss_tail=0.30, miss_lean=0.35, miss_yaw=20.0, power=True, reach=0.96, chain=0.58, recoil=0.36)
    add(u, "rise", "2", "KB_m_Uppercut_%s" % side, action=0.90, pf=0.40, dmg=1.4, sta=1.3, lunge=0.20, lunge_t=0.26, yaw=10.0, dip=1.0, hang=0.06, miss_tail=0.32, miss_lean=0.35, miss_yaw=22.0, power=True, reach=0.96, chain=0.60, recoil=0.38)
    # ---- body shots: same clips, a loaded power version
    for kind, clip, a in (("BodyJab", "%s B J" % side, 0.58), ("BodyHook", "%s B H" % side, 0.74), ("BodyUppercut", "%s B U" % side, 0.70)):
        b = side + kind
        add(b, "power", "", clip, action=round(a * 1.28, 2), pf={"BodyJab": 0.34, "BodyHook": 0.40, "BodyUppercut": 0.42}[kind], dmg=1.3, sta=1.35,
            lunge=0.26, lunge_t=0.26, yaw=7.0, dip=0.8, hang=0.06, miss_tail=0.26, miss_lean=0.5, miss_yaw=14.0, power=True, reach=0.98, chain=round(0.5 * 1.28, 2), recoil=0.34)

json.dump(V, open(OUT, "w"), indent=1)
print("wrote", len(V), "variants")
