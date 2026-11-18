"""python -I tools/make_meshy_sheet.py [out.png] -> contact sheet of _build/shots/mr_<id>_<shot>.png (rows = fighters)"""
import sys, glob, os
from PIL import Image, ImageDraw
ids = []
for p in sorted(glob.glob("_build/shots/mr_*_guard.png")):
    ids.append(os.path.basename(p)[3:-10])
order = ["meshy_viper", "meshy_anvil", "meshy_oak", "meshy_boxer1", "meshy_boxer2"]
ids = [i for i in order if i in ids] + [i for i in ids if i not in order]
shots = ["guard", "hook", "ko1", "ko2"]
tw, th = 560, 315
sheet = Image.new("RGB", (tw * len(shots), th * len(ids)), (20, 20, 20))
for r, fid in enumerate(ids):
    for c, s in enumerate(shots):
        f = f"_build/shots/mr_{fid}_{s}.png"
        if not os.path.exists(f):
            continue
        im = Image.open(f).convert("RGB").resize((tw, th))
        ImageDraw.Draw(im).text((6, 4), f"{fid} {s}", fill=(255, 255, 0))
        sheet.paste(im, (c * tw, r * th))
out = sys.argv[1] if len(sys.argv) > 1 else "_build/meshy_roster_sheet.png"
sheet.save(out); print(sheet.size, out)
