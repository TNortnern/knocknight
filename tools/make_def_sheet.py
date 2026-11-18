"""python -I tools/make_def_sheet.py <dir_a> [<dir_b>] <out.png> [step] [cols]
One dir: contact sheet of f_###.png with timestamps (30 fps). Two dirs: before (left) | after (right), same frames side by side."""
import sys, glob, os
from PIL import Image, ImageDraw
args = sys.argv[1:]
dirs = []
while args and os.path.isdir(args[0]):
    dirs.append(args.pop(0))
out = args.pop(0)
step = int(args.pop(0)) if args else 3
cols = int(args.pop(0)) if args else (6 if len(dirs) == 1 else 4)
def frames(d):
    return sorted(glob.glob(os.path.join(d, "f_*.png")))
fa = [frames(d) for d in dirs]
n = min(len(f) for f in fa)
idx = list(range(0, n, step))
ims = [[Image.open(f[i]).convert("RGB") for i in idx] for f in fa]
w, h = ims[0][0].size
tw = 300 if len(dirs) == 1 else 240
th = int(h * tw / w)
cell_w = tw * len(dirs)
rows = (len(idx) + cols - 1) // cols
sheet = Image.new("RGB", (cell_w * cols + (cols - 1) * 6, (th + 0) * rows), (20, 20, 20))
for k, i in enumerate(idx):
    for j in range(len(dirs)):
        t = ims[j][k].resize((tw, th))
        d = ImageDraw.Draw(t)
        d.text((6, 4), f"{i/30:.2f}s", fill=(255, 255, 0))
        if len(dirs) > 1:
            d.text((tw - 52, 4), "BEFORE" if j == 0 else "AFTER", fill=(255, 120, 120) if j == 0 else (120, 255, 120))
        sheet.paste(t, ((k % cols) * (cell_w + 6) + j * tw, (k // cols) * th))
sheet.save(out)
print(sheet.size)
