"""python -I tools/make_alive_sheet.py out.jpg  -- contact sheet of _build/shots/alive_<case>_NN.png (flinch cases, rows) + idle strip.
Flinch rows: pre, then frames 0..N-1 (0.04 s apart), cropped around the victim (right fighter)."""
import sys, glob, os
from PIL import Image, ImageDraw
out = sys.argv[1]
tw = 330
rows = []
for case in ["jab", "hook", "upper", "body"]:
    files = [f"_build/shots/alive_{case}_pre.png"] + [f"_build/shots/alive_{case}_{i:02d}.png" for i in (0, 1, 2, 4, 7)]
    ims = []
    for k, f in enumerate(files):
        if not os.path.exists(f): continue
        im = Image.open(f).convert("RGB")
        im = im.crop((330, 110, 900, 640)); th = int(im.size[1] * tw / im.size[0]); t = im.resize((tw, th))
        lab = "pre" if k == 0 else f"{[0,1,2,4,7][k-1]*0.04+0.04:.2f}s"
        ImageDraw.Draw(t).text((4, 3), f"{case} {lab}", fill=(255, 255, 0))
        ims.append(t)
    rows.append(ims)
idle = sorted(glob.glob("_build/shots/alive_idle_[0-9]*.png"))
if idle:
    ims = []
    for k, f in enumerate(idle[1:11:2]):
        im = Image.open(f).convert("RGB"); w, h = im.size
        im = im.crop((int(w * 0.28), int(h * 0.12), int(w * 0.72), int(h * 0.95))); th = int(im.size[1] * tw / im.size[0]); t = im.resize((tw, th))
        ImageDraw.Draw(t).text((4, 3), f"idle {(k + 1) * 0.2:.1f}s", fill=(255, 255, 0))
        ims.append(t)
    rows.append(ims)
cols = max(len(r) for r in rows); hs = [max(t.size[1] for t in r) for r in rows]
sheet = Image.new("RGB", (tw * cols, sum(hs)))
y = 0
for r, ims in enumerate(rows):
    for c, t in enumerate(ims): sheet.paste(t, (c * tw, y))
    y += hs[r]
sheet.save(out, quality=88); print(out, sheet.size)
