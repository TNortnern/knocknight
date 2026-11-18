"""python -I tools/make_guard_sheet.py <out.jpg> [first] [last] : rows = parry / pierce / uppercut / knock from tests/capture_guard_moves.gd"""
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]
a = int(sys.argv[2]) if len(sys.argv) > 2 else 2
b = int(sys.argv[3]) if len(sys.argv) > 3 else 12
tw = 420
rows = []
for name in ["parry", "pierce", "uppercut", "knock"]:
    ims = []
    for k in range(a, b):
        try: im = Image.open(f"_build/shots/gm_{name}_{k:02d}.png").convert("RGB")
        except Exception: continue
        w, h = im.size
        im = im.crop((int(w * 0.30), int(h * 0.20), int(w * 0.72), int(h * 0.75)))
        im = im.resize((tw, int(im.size[1] * tw / im.size[0])))
        d = ImageDraw.Draw(im); d.text((4, 3), f"{name} {k*0.05:.2f}s", fill=(255, 255, 0))
        ims.append(im)
    rows.append(ims)
n = max(len(r) for r in rows); th = rows[0][0].size[1]
sh = Image.new("RGB", (tw * n, th * len(rows)))
for y, r in enumerate(rows):
    for x, im in enumerate(r):
        sh.paste(im, (x * tw, y * th))
sh.save(out, quality=88); print(out, sh.size)
