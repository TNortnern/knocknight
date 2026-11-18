"""python -I tools/make_strip.py <tag> <out.png> [start] [stop] [step] [cols] : one contact strip of a capture (_build/shots/<tag>_NN.png)"""
import sys
from PIL import Image
tag, out = sys.argv[1], sys.argv[2]
start = int(sys.argv[3]) if len(sys.argv) > 3 else 2
stop = int(sys.argv[4]) if len(sys.argv) > 4 else 26
step = int(sys.argv[5]) if len(sys.argv) > 5 else 2
cols = int(sys.argv[6]) if len(sys.argv) > 6 else 6
tw = 420
ims = []
for k in range(start, stop, step):
    try: im = Image.open(f"_build/shots/{tag}_{k:02d}.png").convert("RGB")
    except Exception: continue
    w, h = im.size
    im = im.crop((int(w * 0.2), int(h * 0.25), int(w * 0.8), int(h * 0.92)))
    im = im.resize((tw, int(im.size[1] * tw / im.size[0])))
    ims.append(im)
rows = (len(ims) + cols - 1) // cols
sh = Image.new("RGB", (tw * cols, ims[0].size[1] * rows))
for i, im in enumerate(ims):
    sh.paste(im, ((i % cols) * tw, (i // cols) * im.size[1]))
sh.save(out); print(out, sh.size)
