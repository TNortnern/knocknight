"""python -I tools/make_hits_sheet.py <tag> <out.jpg> [n_hits] [cols] [tw]
Contact sheet of the film frames at the moments blows landed (reads _build/film/<tag>_hits.txt written by tools/film_fight.gd; frames
are taken every `every` s, the hit log time / every = frame index). Each tile is labelled with time, strike, zone and outcome."""
import sys
from PIL import Image, ImageDraw
tag, out = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 12
cols = int(sys.argv[4]) if len(sys.argv) > 4 else 4
tw = int(sys.argv[5]) if len(sys.argv) > 5 else 420
every = 0.05
rows = []
for line in open(f"_build/film/{tag}_hits.txt").read().splitlines():
    p = line.split()
    if len(p) < 6:
        continue
    rows.append((float(p[0]), p[1], p[2], p[3], p[4], p[5]))
# spread the picks over the whole film, one per ~0.8 s at most, mixing blocked / glance / clean
picked, last = [], -9.0
for r in rows:
    if r[0] - last >= 0.8:
        picked.append(r)
        last = r[0]
picked = picked[:n]
ims = []
for t, who, strike, zone, blocked, glance in picked:
    k = int(round(t / every)) + 2   # the flash is drawn the frame after the hit
    try:
        im = Image.open(f"_build/film/{tag}_{k:03d}.png").convert("RGB")
    except Exception:
        continue
    w, h = im.size
    im = im.crop((int(w * 0.20), int(h * 0.18), int(w * 0.80), int(h * 0.82)))
    im = im.resize((tw, int(im.size[1] * tw / im.size[0])))
    d = ImageDraw.Draw(im)
    tag_txt = "GLANCE" if glance.endswith("True") else ("BLOCK" if blocked.endswith("True") else "HIT")
    d.rectangle((0, 0, tw, 16), fill=(0, 0, 0))
    d.text((4, 2), f"{t:.2f}s {who} {strike} {zone} {tag_txt}", fill=(255, 255, 0))
    ims.append(im)
rws = (len(ims) + cols - 1) // cols
sh = Image.new("RGB", (tw * cols, ims[0].size[1] * rws))
for i, im in enumerate(ims):
    sh.paste(im, ((i % cols) * tw, (i // cols) * im.size[1]))
sh.save(out, quality=88)
print(out, sh.size, len(ims), "tiles")
