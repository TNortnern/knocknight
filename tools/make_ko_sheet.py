"""python -I tools/make_ko_sheet.py <out.png> <cols> <step> <dt> <tag1> [tag2 ...]
One contact sheet, one row per capture tag (_build/shots/<tag>_NN.png), `cols` frames per row every `step` frames.
Centre-crops each frame around the action (the fight camera frames the fallen body in the middle)."""
import sys, glob
from PIL import Image, ImageDraw
out = sys.argv[1]; cols = int(sys.argv[2]); step = int(sys.argv[3]); dt = float(sys.argv[4]); tags = sys.argv[5:]
tw = 440
rows = []
for tag in tags:
    files = sorted(glob.glob(f"_build/shots/{tag}_[0-9]*.png"), key=lambda p: int(p.rsplit("_", 1)[1][:-4]))[::step][:cols]
    ims = []
    for i, f in enumerate(files):
        im = Image.open(f).convert("RGB"); w, h = im.size
        im = im.crop((int(w * 0.12), int(h * 0.18), int(w * 0.88), int(h * 0.92)))
        th = int(im.size[1] * tw / im.size[0]); t = im.resize((tw, th))
        ImageDraw.Draw(t).text((5, 3), f"{tag} {i*step*dt:.2f}s", fill=(255, 255, 0))
        ims.append(t)
    rows.append(ims)
th = rows[0][0].size[1]
sheet = Image.new("RGB", (tw * cols, th * len(rows)))
for r, ims in enumerate(rows):
    for c, t in enumerate(ims):
        sheet.paste(t, (c * tw, r * th))
sheet.save(out); print(out, sheet.size)
