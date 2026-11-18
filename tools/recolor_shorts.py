#!/usr/bin/env python3
"""Texture-only shorts readability edit for the Meshy fighters whose shorts sit at the skin's luminance (anvil, oak).

Why: the shorts hid the thigh / knee bend (dark trunks next to dark skin = one mass). This lifts the shorts' dark
texels and paints a contrasting band along the hem so the leg line and the knee read in motion.

How the shorts are isolated (no mesh, rig or UV changes):
  * triangles whose bind-pose centroid is in the trunks' height band (SHORTS_Y) and whose skin weights are >= 85 %
    on Hips / Spine02 / UpLeg bones  -> candidate triangles;
  * their UV polygons are rasterised into a mask (dilated 2 px);
  * only texels that are NOT skin (brown/tan) and NOT already a bright trim colour are recoloured, so a skin island
    that touches the mask is untouched;
  * the hem band = candidate triangles lower than HEM_BAND metres above each leg's lowest hem vertex.

The ORIGINAL textures are read from git (commit ORIG_COMMIT), never from the working tree, so the script is
idempotent and the originals stay recoverable (`git show ORIG_COMMIT:<path>`).

usage: python tools/recolor_shorts.py [--debug DIR] [anvil|oak ...]   (run from the repo root)
"""
import io, json, struct, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ORIG_COMMIT = "6b23eb3"
DIR = "assets/fighters/meshy/"
CFG = {
    "anvil": {"glb": "anvil.glb", "tex": "anvil_fighter42a_baseColor.jpg",
              "gamma": 0.74, "tint": (0.95, 1.0, 1.08), "cap": 118, "band": (52, 160, 158), "hem_band": 0.05},
    "oak": {"glb": "oak.glb", "tex": "oak_fighter42c_baseColor.jpg",
            "gamma": 0.86, "tint": (0.97, 1.0, 1.10), "cap": 150, "band": (150, 120, 48), "hem_band": 0.05},
}
SHORTS_Y = (0.33, 0.645)    # fraction of the mesh height: hem .. waistband
BONE_SHARE = 0.85


def glb_primitive(path):
    d = open(path, "rb").read()
    ln = struct.unpack("<I", d[8:12])[0]
    off, js, bn = 12, None, None
    while off < ln:
        cl, ct = struct.unpack("<I4s", d[off:off + 8]); off += 8
        if ct == b"JSON": js = json.loads(d[off:off + cl])
        elif ct == b"BIN\x00": bn = d[off:off + cl]
        off += cl

    def acc(i):
        a = js["accessors"][i]; bv = js["bufferViews"][a["bufferView"]]
        nc = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}[a["componentType"]]
        off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        return np.frombuffer(bn, dtype=dt, count=a["count"] * nc, offset=off).reshape(a["count"], nc)
    p = js["meshes"][0]["primitives"][0]; at = p["attributes"]
    sk = js["skins"][0]; jn = [js["nodes"][j]["name"] for j in sk["joints"]]
    return (jn, acc(at["POSITION"]).astype(float), acc(at["TEXCOORD_0"]).astype(float), acc(at["JOINTS_0"]).astype(int),
            acc(at["WEIGHTS_0"]).astype(float), acc(p["indices"]).reshape(-1, 3).astype(int))


def orig_texture(name):
    blob = subprocess.check_output(["git", "show", "%s:%s%s" % (ORIG_COMMIT, DIR, name)])
    return Image.open(io.BytesIO(blob)).convert("RGB")


def run(model, debug_dir=None):
    c = CFG[model]
    jn, P, UV, J, W, T = glb_primitive(DIR + c["glb"])
    W = W / np.maximum(W.sum(1, keepdims=True), 1e-9)
    ymin = P[:, 1].min(); H = P[:, 1].max() - ymin
    grp = np.array([n in ("Hips", "Spine02", "LeftUpLeg", "RightUpLeg") for n in jn])
    vshare = np.zeros(len(P))
    for k in range(4):
        vshare += W[:, k] * grp[J[:, k]]
    cy = (P[T, 1].mean(1) - ymin) / H
    tshare = vshare[T].mean(1)
    cand = (cy >= SHORTS_Y[0]) & (cy <= SHORTS_Y[1]) & (tshare >= BONE_SHARE) & (np.abs(P[T, 0].mean(1) - P[:, 0].mean()) < 0.22 * H)
    print(model, "triangles", len(T), "shorts candidates", int(cand.sum()))
    # hem band: per leg (x sign) lowest vertex of the candidate triangles
    xs = P[T, 0].mean(1) - P[:, 0].mean()
    band = np.zeros(len(T), bool)
    for side in (xs < 0, xs >= 0):
        sel = cand & side
        if not sel.any(): continue
        low = np.percentile(P[T[sel], 1], 2)
        band |= sel & (P[T, 1].mean(1) < low + c["hem_band"])
    print("  hem band triangles", int(band.sum()))
    tex = orig_texture(c["tex"]); S = tex.size[0]
    arr = np.array(tex).astype(float)

    def mask_of(tris):
        m = Image.new("L", (S, S), 0); d = ImageDraw.Draw(m)
        for t in tris:
            d.polygon([(UV[i, 0] * S, UV[i, 1] * S) for i in T[t]], fill=255)
        return m.filter(ImageFilter.MaxFilter(5))   # 2 px dilation (mip bleed)

    m_sh = np.array(mask_of(np.where(cand)[0])) > 0
    m_band = np.array(mask_of(np.where(band)[0])) > 0
    r, g, b = arr[..., 0], arr[..., 1], arr[..., 2]
    skin = (r > b + 14) & (r >= g) & (r > 30)                       # brown / tan skin islands
    bright = (arr.max(-1) > 110)                                     # existing bright trims / white panels
    base = m_sh & ~skin & ~bright
    out = arr.copy()
    # lift: gamma on the dark texels, blue-ish tint, capped so folds keep their relative shading
    lifted = 255.0 * (arr / 255.0) ** c["gamma"]
    lifted = np.minimum(lifted * np.array(c["tint"]), c["cap"])
    out[base] = lifted[base]
    band_px = m_band & ~skin
    out[band_px] = np.array(c["band"], float) * (0.55 + 0.45 * (arr[band_px].max(-1, keepdims=True) / 60.0).clip(0, 1))
    res = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    res.save(DIR + c["tex"], quality=97, subsampling=0)
    print("  recoloured texels: lift %d, hem band %d (of %d)" % (int(base.sum()), int(band_px.sum()), S * S))
    if debug_dir:
        res.save("%s/%s_after.png" % (debug_dir, model))
        tex.save("%s/%s_before.png" % (debug_dir, model))
        ov = np.array(tex); ov[base] = (255, 0, 255); ov[band_px] = (255, 255, 0)
        Image.fromarray(ov).save("%s/%s_mask.png" % (debug_dir, model))


if __name__ == "__main__":
    args = sys.argv[1:]
    dbg = None
    if args[:1] == ["--debug"]:
        dbg = args[1]; args = args[2:]
    for m in (args or list(CFG)):
        run(m, dbg)
