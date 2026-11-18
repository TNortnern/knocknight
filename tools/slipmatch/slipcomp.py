"""Side-by-side reference (left) vs current game (right) composites at matched real-time offsets.

usage: python -I slipcomp.py --ref VIDEO --ref-start S --dur D --ref-crop x,y,w,h
                             --game DIR --game-start S --game-crop x,y,w,h --out DIR --title TEXT
Writes key.jpg (8 matched instants), dense.jpg (every 2nd frame, 15 fps), sbs.gif (30 fps).
"""
import argparse, glob, os, subprocess
from PIL import Image, ImageDraw, ImageFont

FPS = 30
FONT = "C:/Windows/Fonts/arialbd.ttf"


def font(sz):
    try:
        return ImageFont.truetype(FONT, sz)
    except OSError:
        return ImageFont.load_default()


def crop_box(s):
    x, y, w, h = [int(v) for v in s.split(",")]
    return (x, y, x + w, y + h)


def ref_frames(video, start, dur, cache):
    os.makedirs(cache, exist_ok=True)
    tag = os.path.join(cache, "ref_%.3f_%.3f" % (start, dur))
    if not os.path.isdir(tag):
        os.makedirs(tag)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", "%.4f" % start, "-i", video, "-t", "%.4f" % (dur + 0.05),
                        "-vf", "fps=%d" % FPS, os.path.join(tag, "f_%04d.png")], check=True)
    return sorted(glob.glob(os.path.join(tag, "f_*.png")))


def game_frames(d):
    fs = sorted(f for f in glob.glob(os.path.join(d, "*.png")) if "_sheet" not in f and "preview" not in f)
    return fs


def fit(img, box, h):
    im = img.crop(box)
    w = round(im.width * h / im.height)
    return im.resize((w, h), Image.LANCZOS)


def pair(ref_img, game_img, rbox, gbox, h, label):
    a = fit(ref_img, rbox, h)
    b = fit(game_img, gbox, h)
    head = 30
    out = Image.new("RGB", (a.width + b.width + 6, h + head), (12, 12, 12))
    out.paste(a, (0, head))
    out.paste(b, (a.width + 6, head))
    d = ImageDraw.Draw(out)
    d.text((6, 4), label, fill=(255, 230, 60), font=font(20))
    d.text((6, head + 6), "REFERENCE", fill=(255, 255, 255), font=font(18), stroke_width=2, stroke_fill=(0, 0, 0))
    d.text((a.width + 12, head + 6), "CURRENT", fill=(120, 220, 255), font=font(18), stroke_width=2, stroke_fill=(0, 0, 0))
    return out


def grid(cells, cols, title):
    cw = max(c.width for c in cells)
    ch = max(c.height for c in cells)
    rows = (len(cells) + cols - 1) // cols
    top = 44
    sheet = Image.new("RGB", (cols * cw + (cols + 1) * 8, top + rows * ch + (rows + 1) * 8), (40, 40, 40))
    d = ImageDraw.Draw(sheet)
    d.text((10, 8), title, fill=(255, 255, 255), font=font(26))
    for i, c in enumerate(cells):
        r, k = divmod(i, cols)
        sheet.paste(c, (8 + k * (cw + 8), top + 8 + r * (ch + 8)))
    return sheet


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--ref-start", type=float, required=True)
    ap.add_argument("--dur", type=float, required=True)
    ap.add_argument("--ref-crop", required=True)
    ap.add_argument("--game", required=True)
    ap.add_argument("--game-start", type=float, required=True)
    ap.add_argument("--game-crop", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--cache", default=None)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rf = ref_frames(a.ref, a.ref_start, a.dur, a.cache or os.path.join(os.path.dirname(a.out), "_refcache"))
    gf = game_frames(a.game)
    rbox, gbox = crop_box(a.ref_crop), crop_box(a.game_crop)
    n = int(round(a.dur * FPS))

    def at(k):   # k-th 30 fps frame of the window, both sides at the same real-time offset
        ri = min(k, len(rf) - 1)
        gi = min(int(round(a.game_start * FPS)) + k, len(gf) - 1)
        return Image.open(rf[ri]).convert("RGB"), Image.open(gf[gi]).convert("RGB")

    keys = [round(i * n / 7) for i in range(8)]
    cells = []
    for k in keys:
        r, g = at(k)
        cells.append(pair(r, g, rbox, gbox, 420, "+%.2fs" % (k / FPS)))
    grid(cells, 4, a.title + "  -  8 matched instants (real time, same offset both sides)").save(os.path.join(a.out, "key.jpg"), quality=88)

    cells = []
    for k in range(0, n + 1, 2):
        r, g = at(k)
        cells.append(pair(r, g, rbox, gbox, 260, "+%.3fs" % (k / FPS)))
    grid(cells, 7, a.title + "  -  every frame at 15 fps (motion speed / flow)").save(os.path.join(a.out, "dense.jpg"), quality=85)

    frames = []
    for k in range(n + 1):
        r, g = at(k)
        frames.append(pair(r, g, rbox, gbox, 400, a.title + "  +%.3fs" % (k / FPS)).convert("P", palette=Image.ADAPTIVE))
    frames[0].save(os.path.join(a.out, "sbs.gif"), save_all=True, append_images=frames[1:], duration=int(1000 / FPS), loop=0)
    print("wrote", a.out, "ref frames", len(rf), "game frames", len(gf), "window frames", n + 1)


if __name__ == "__main__":
    main()
