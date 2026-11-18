"""python -I tools/make_hits_sheet2.py out.jpg case1 [case2 ...] [--cols 6] [--before 4] [--after 11] [--tw 300] [--crop x0,y0,x1,y1 (fractions)] [--dir frames_dir/]
Contact sheet of capture_hits.gd cases (_build/hits/frames/<case>_NNN.png, one every 4th physics tick at 120 Hz = 30 fps): each case is one row of
frames from `before` frames ahead of the hit to `after` frames behind it; the hit frame has a red border. Labelled with case / frame offset."""
import json
import sys
from PIL import Image, ImageDraw

args = sys.argv[1:]
out = args[0]
opts = {"--cols": 6, "--before": 4, "--after": 11, "--tw": 300}
crop = (0.30, 0.22, 0.72, 0.82)
FRAMES_DIR = "_build/hits/frames/"
cases = []
i = 1
while i < len(args):
    a = args[i]
    if a == "--dir":
        FRAMES_DIR = args[i + 1]
        i += 2
    elif a == "--crop":
        crop = tuple(float(x) for x in args[i + 1].split(","))
        i += 2
    elif a in opts:
        opts[a] = int(args[i + 1])
        i += 2
    else:
        cases.append(a)
        i += 1
D = FRAMES_DIR
rows = []
for c in cases:
    meta = json.load(open(D + c + ".json"))
    h = meta["hit_frame"]
    if h < 0:
        h = 8
    first = max(0, h - opts["--before"])
    last = min(meta["frames"] - 1, h + opts["--after"])
    tiles = []
    for k in range(first, last + 1):
        im = Image.open(D + "%s_%03d.png" % (c, k)).convert("RGB")
        w, hh = im.size
        im = im.crop((int(w * crop[0]), int(hh * crop[1]), int(w * crop[2]), int(hh * crop[3])))
        tw = opts["--tw"]
        im = im.resize((tw, int(im.size[1] * tw / im.size[0])))
        d = ImageDraw.Draw(im)
        d.rectangle((0, 0, tw, 14), fill=(0, 0, 0))
        d.text((3, 1), "%s %+d" % (c, k - h), fill=(255, 255, 0))
        if k == h:
            d.rectangle((0, 0, im.size[0] - 1, im.size[1] - 1), outline=(255, 40, 40), width=3)
        tiles.append(im)
    rows.append((c, meta, tiles))
cols = opts["--cols"]
th = rows[0][2][0].size[1]
tw = rows[0][2][0].size[0]
total_rows = sum((len(t) + cols - 1) // cols for _, _, t in rows)
sheet = Image.new("RGB", (cols * tw, total_rows * th), (20, 20, 20))
r = 0
for c, meta, tiles in rows:
    for n, im in enumerate(tiles):
        sheet.paste(im, ((n % cols) * tw, (r + n // cols) * th))
    r += (len(tiles) + cols - 1) // cols
sheet.save(out, quality=88)
print(out, sheet.size)
