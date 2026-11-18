"""python -I tools/make_lean_sheet.py out.jpg scenario1 scenario2 ... : one row per scenario from _build/shots/lean/<scenario>_NN.png"""
import sys, glob
from PIL import Image, ImageDraw
out = sys.argv[1]; names = sys.argv[2:]
rows = []
for n in names:
    fs = sorted(glob.glob(f"_build/shots/lean/{n}_*.png"))
    ims = []
    for i, p in enumerate(fs):
        im = Image.open(p).convert("RGB"); w, h = im.size
        c = im.crop((int(w*0.18), int(h*0.04), int(w*0.82), int(h*0.96))).resize((300, 300))
        ImageDraw.Draw(c).text((6, 4), f"{n} {i}", fill=(255, 255, 0)); ims.append(c)
    rows.append(ims)
W = max(len(r) for r in rows) * 300
sheet = Image.new("RGB", (W, 300 * len(rows)))
for y, r in enumerate(rows):
    for x, c in enumerate(r): sheet.paste(c, (x * 300, y * 300))
sheet.save(out, quality=85); print(sheet.size)
