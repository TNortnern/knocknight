"""python -I tools/make_sheet.py <tag> [cols] [step] -> _build/shots/<tag>_sheet.png (contact sheet of the capture frames)"""
import sys, glob
from PIL import Image, ImageDraw
tag = sys.argv[1]; cols = int(sys.argv[2]) if len(sys.argv) > 2 else 6; step = int(sys.argv[3]) if len(sys.argv) > 3 else 1
start = int(sys.argv[4]) if len(sys.argv) > 4 else 0
dt = float(sys.argv[5]) if len(sys.argv) > 5 else 0.15
files = sorted(glob.glob(f"_build/shots/{tag}_[0-9]*.png"), key=lambda p: int(p.rsplit("_",1)[1][:-4]))[start::step]
ims = [Image.open(f).convert("RGB") for f in files]
w, h = ims[0].size; tw = 480; th = int(h * tw / w)
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (tw * cols, th * rows))
for i, im in enumerate(ims):
    t = im.resize((tw, th)); d = ImageDraw.Draw(t); d.text((6, 4), f"{i*step+start}  t={(i*step+start)*dt:.2f}s", fill=(255, 255, 0))
    sheet.paste(t, ((i % cols) * tw, (i // cols) * th))
sheet.save(f"_build/shots/{tag}_sheet.png"); print(sheet.size)
