"""python -I tools/make_film_sheet.py <tag> <out.png> <start> <stop> <step> [cols] [tw] : contact sheet of _build/film/<tag>_NNN.png"""
import sys
from PIL import Image, ImageDraw
tag, out = sys.argv[1], sys.argv[2]
start, stop, step = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
cols = int(sys.argv[6]) if len(sys.argv) > 6 else 6
tw = int(sys.argv[7]) if len(sys.argv) > 7 else 330
ims = []
for k in range(start, stop, step):
    try: im = Image.open(f"_build/film/{tag}_{k:03d}.png").convert("RGB")
    except Exception: continue
    w, h = im.size
    im = im.crop((int(w * 0.18), int(h * 0.30), int(w * 0.82), int(h * 0.88)))
    im = im.resize((tw, int(im.size[1] * tw / im.size[0])))
    ImageDraw.Draw(im).text((4, 3), f"{k*0.1:.1f}s", fill=(255, 255, 0))
    ims.append(im)
rows = (len(ims) + cols - 1) // cols
sh = Image.new("RGB", (tw * cols, ims[0].size[1] * rows))
for i, im in enumerate(ims):
    sh.paste(im, ((i % cols) * tw, (i // cols) * im.size[1]))
sh.save(out); print(out, sh.size)
