"""python -I tools/probe_compare.py "<before glob>" "<after glob>"   - the before / after table of tools/probe_hits.gd runs (markdown)."""
import glob
import importlib.util
import sys
from collections import Counter

spec = importlib.util.spec_from_file_location("rep", __file__.replace("probe_compare.py", "probe_hits_report.py"))
rep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rep)


def pct(a, b):
    return "%.1f%%" % (100.0 * a / b) if b else "n/a"


def med(v):
    v = sorted(v)
    return v[len(v) // 2] if v else 0.0


def metrics(rows, label):
    m = {}
    sc = [r for r in rows if r["mode"] == "scripted"]
    m["punches"] = len(rows)
    vc = [r for r in rows if rep.visible_contact(r)]
    m["visible contacts"] = len(vc)
    fn = [r for r in vc if r["outcome"] == "whiff"]
    m["FALSE NEGATIVES (visible touch, whiff)"] = "%d (%s)" % (len(fn), pct(len(fn), len(vc)))
    for st in ("idle", "block", "slip", "cpu"):
        sub = [r for r in vc if r["state"] == st]
        f2 = [r for r in sub if r["outcome"] == "whiff"]
        m["  ... foe %s" % st] = "%d / %d (%s)" % (len(f2), len(sub), pct(len(f2), len(sub)))
    reg = [r for r in rows if r["outcome"] in rep.REG]
    fp = [r for r in reg if rep.vis_min(r) > rep.FP_FAR and r["outcome"] != "clash"]
    m["FALSE POSITIVES (registered, nothing within 3 cm)"] = "%d (%s)" % (len(fp), pct(len(fp), len(reg)))
    c = Counter(r["outcome"] for r in rows)
    m["outcomes hit / glance / block / parry / clash / evaded / whiff"] = " / ".join(str(c[k]) for k in ("hit", "glance", "block", "parry", "clash", "evaded", "whiff"))
    heads = [r for r in rows if r["outcome"] == "hit" and r["zone"] == "head" and r["vis_head"] <= rep.VIS_TOUCH]
    deep = [r for r in heads if r["vis_head_inside"] >= 0.25]
    m["clean head hits with glove >= 25% inside the visible head"] = "%d of %d (%s)" % (len(deep), len(heads), pct(len(deep), len(heads)))

    def vis_react(r):
        if r["outcome"] in ("block", "parry", "clash"):
            return rep.peak(r, ("Head", "Chest", "LGlove", "RGlove")) > rep.VISIBLE
        return rep.peak(r, ("Head", "Chest")) > rep.VISIBLE
    for oc in ("hit", "glance", "block", "evaded"):
        sub = [r for r in rows if r["outcome"] == oc and r.get("react") and r["mode"] == "scripted"]
        m["%s: share with a visible reaction (scripted)" % oc] = "%s (n=%d)" % (pct(sum(vis_react(r) for r in sub), len(sub)), len(sub))
        m["%s: median head / chest / glove motion, cm" % oc] = "%.1f / %.1f / %.1f" % (
            med([rep.peak(r, ("Head",)) for r in sub]) * 100, med([rep.peak(r, ("Chest",)) for r in sub]) * 100, med([rep.peak(r, ("LGlove", "RGlove")) for r in sub]) * 100)
    w = [r for r in rows if r["outcome"] == "whiff" and rep.visible_contact(r) and r.get("react") and r["mode"] == "scripted"]
    m["visible touch registered as whiff: share with any head / chest motion"] = "%s (n=%d)" % (pct(sum(vis_react(r) for r in w), len(w)), len(w))
    allreg = [r for r in rows if r["outcome"] in rep.REG and r.get("react") and r["mode"] == "scripted"]
    nr = [r for r in allreg if not vis_react(r)]
    m["registered outcomes with NO visible reaction (scripted)"] = "%d of %d (%s)" % (len(nr), len(allreg), pct(len(nr), len(allreg)))
    dmg = sum(max(r["damage"], 0.0) for r in rows)
    m["total damage dealt by the %d punches" % len(rows)] = "%.0f (mean %.2f per punch, %.2f per visible contact)" % (dmg, dmg / max(len(rows), 1), dmg / max(len(vc), 1))
    zero = [r for r in rows if r["outcome"] == "hit" and r["damage"] < 0.01]
    m["registered clean hits that did zero damage"] = str(len(zero))
    return m


if __name__ == "__main__":
    b = metrics(rep.load(sorted(glob.glob(sys.argv[1]))), "before")
    a = metrics(rep.load(sorted(glob.glob(sys.argv[2]))), "after")
    print("| metric | before (fn3/hits base logic) | after |")
    print("|---|---|---|")
    for k in b:
        print("| %s | %s | %s |" % (k, b[k], a.get(k, "")))
