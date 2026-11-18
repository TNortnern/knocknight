"""python -I tools/crop_sheet.py <tag> <out> f1 f2 ... : crops the fighters' area from chosen frames into one strip (_build/shots/<out>.png)"""
import sys
from PIL import Image, ImageDraw
tag, out = sys.argv[1], sys.argv[2]; fr = [int(x) for x in sys.argv[3:]]
ims = [Image.open(f"_build/shots/{tag}_{i:02d}.png").convert("RGB") for i in fr]
w, h = ims[0].size
box = (int(w*0.12), int(h*0.2), int(w*0.88), int(h*0.85))
cw, ch = box[2]-box[0], box[3]-box[1]
sc = 0.5; tw, th = int(cw*sc), int(ch*sc)
cols = min(3, len(ims)); rows = (len(ims)+cols-1)//cols
sheet = Image.new("RGB", (tw*cols, th*rows))
for k, im in enumerate(ims):
    t = im.crop(box).resize((tw, th)); ImageDraw.Draw(t).text((6,4), str(fr[k]), fill=(255,255,0)); sheet.paste(t, ((k%cols)*tw, (k//cols)*th))
sheet.save(f"_build/shots/{out}.png"); print(sheet.size)
