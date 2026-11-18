"""python -I tools/make_slips_sheet.py out.jpg model1 [model2]: rows of our frames (_build/shots/slips/<model>_<scn>_NN.png), 10 fps."""
import sys, glob
from PIL import Image, ImageDraw
out = sys.argv[1]; models = sys.argv[2:]
scn = ["slip_l", "slip_r", "back", "duck", "slip_counter"]
C = 190
rows = []
for mdl in models:
    for s in scn:
        fs = sorted(glob.glob(f"_build/shots/slips/{mdl}_{s}_*.png"))
        ims = []
        for i, p in enumerate(fs):
            im = Image.open(p).convert("RGB"); w, h = im.size
            c = im.crop((int(w*0.36), int(h*0.06), int(w*0.64), int(h*0.96))).resize((C, int(C * 0.9*900/(0.28*1600))))
            ImageDraw.Draw(c).text((4, 3), f"{mdl[:8]} {s} {i/10:.1f}s", fill=(255, 255, 0)); ims.append(c)
        rows.append(ims)
Wd = max(len(r) for r in rows) * C; Hh = max(r[0].size[1] for r in rows if r)
sheet = Image.new("RGB", (Wd, Hh * len(rows)))
for y, r in enumerate(rows):
    for x, c in enumerate(r): sheet.paste(c, (x * C, y * Hh))
sheet.save(out, quality=85); print(sheet.size)
