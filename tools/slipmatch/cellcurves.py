"""Head / shoulder-mid / hip-mid travel in composite-cell units (fractions of the crop width/height), reference vs game.

This is the motion as the graders see it in the side-by-side cells (posecurves.py normalises by torso length instead).
usage: python -I cellcurves.py MODEL REF_DIR REF_CROP GAME_DIR GAME_START GAME_CROP DUR
Columns: dx/dy from frame 0, + = screen-right / down. Pose-model detections on the rear C view are unreliable.
"""
import sys, glob, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import posecurves as pc
import numpy as np
model, rdir, rcrop, gdir, gstart, gcrop, dur = sys.argv[1:8]
n = int(round(float(dur) * 30)) + 1
rf = sorted(glob.glob(os.path.join(rdir, "f_*.png")))[:n]
gf = sorted(f for f in glob.glob(os.path.join(gdir, "*.png")) if "_sheet" not in f and "preview" not in f)
g0 = int(round(float(gstart) * 30)); gf = gf[g0:g0 + n]
def run(frames, crop):
    box = pc.crop_box(crop); W = box[2]-box[0]; H = box[3]-box[1]
    out = []
    for L in pc.measure(model, frames, box):
        if L is None: out.append(None); continue
        head = (pc.pt(L, pc.NOSE) + pc.pt(L, pc.LEAR) + pc.pt(L, pc.REAR)) / 3
        sh = pc.mid(L, pc.LSH, pc.RSH); shw = abs(L[pc.LSH][0]-L[pc.RSH][0])
        out.append((head[0]/W, head[1]/H, shw/W, sh[0]/W, sh[1]/H, (pc.mid(L,pc.LHIP,pc.RHIP)[0])/W))
    return out
r = run(rf, rcrop); g = run(gf, gcrop)
r0 = next(x for x in r if x); g0_ = next(x for x in g if x)
print("frame0 shoulder width / cell width: ref %.3f  game %.3f" % (r0[2], g0_[2]))
print("t    | ref: head_dx head_dy sh_dx sh_dy hip_dx | game: head_dx head_dy sh_dx sh_dy hip_dx")
for i in range(0, n, 3):
    a = r[i] if i < len(r) else None; b = g[i] if i < len(g) else None
    f = lambda a, z: (" ".join("%+.3f" % (a[k]-z[k]) for k in (0,1,3,4,5))) if a else "nan"
    fa = f(a, r0); fb = f(b, g0_)
    print("%.2f  %s | %s" % (i/30, fa, fb))
