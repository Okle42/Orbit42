# FreeCAD 無頭轉檔：STEP/IGES/BREP/FCStd/3MF… → Orbit42 的 .o42m（第一行 JSON，後面接 float32／uint32）
# 路徑走環境變數 O42_IN／O42_OUT（freecadcmd 會把參數當檔案打開）；錯誤寫到 O42_OUT + ".err"
import os, json, math, array, traceback
SRC, OUT = os.environ["O42_IN"], os.environ["O42_OUT"]

def collect():
    import FreeCAD as A, Part
    ext = SRC.rsplit(".", 1)[-1].lower()
    name = os.path.basename(SRC)
    if ext in ("3mf", "off"):
        import Mesh
        return [(name, None, Mesh.Mesh(SRC))]
    if ext in ("brep", "brp", "iges", "igs"):
        s = Part.Shape(); s.read(SRC)
        return [(name, s, None)]
    if ext == "fcstd":
        d = A.openDocument(SRC, True)
    else:
        import Import
        d = A.newDocument("o42"); Import.insert(SRC, d.Name)
    parts = []
    for o in d.Objects:
        if o.isDerivedFrom("Mesh::Feature"):
            parts.append((o.Label, None, o.Mesh)); continue
        if not o.isDerivedFrom("Part::Feature"): continue
        if any(p.isDerivedFrom("Part::Feature") for p in o.InList): continue   # 被別的特徵用掉的中間步驟
        s = o.Shape
        if s.isNull() or not s.Faces: continue
        s = s.copy(); s.Placement = o.getGlobalPlacement()
        sol = s.Solids
        if len(sol) > 1: parts += [("%s %d" % (o.Label, i + 1), x, None) for i, x in enumerate(sol)]
        else: parts.append((o.Label, s, None))
    return parts

def main():
    parts = collect()
    if not parts: raise RuntimeError("檔案裡沒有可以顯示的實體或網格")
    diag = max((s or m).BoundBox.DiagonalLength for _, s, m in parts)
    defl = max(0.02, diag / 3000.0)
    head, blob = [], []
    for name, s, m in parts:
        pos, nor, idx, seg = array.array("f"), array.array("f"), array.array("I"), array.array("f")
        groups = []
        if m is not None:                                   # 網格：每個三角形自己的法線
            pts = [tuple(p.Vector) for p in m.Points]
            vs = [pts[i] for f in m.Facets for i in f.PointIndices]
            groups.append((vs, [(i, i + 1, i + 2) for i in range(0, len(vs), 3)]))
        else:
            for f in s.Faces:
                vs, ts = f.tessellate(defl)
                groups.append(([tuple(v) for v in vs], ts))
            for e in s.Edges:
                try: ps = e.discretize(Deflection=defl)
                except Exception: continue
                for a, b in zip(ps, ps[1:]): seg.extend((a.x, a.y, a.z, b.x, b.y, b.z))
        for vs, ts in groups:
            base = len(pos) // 3
            ns = [[0.0, 0.0, 0.0] for _ in vs]
            for a, b, c in ts:
                u = [vs[b][i] - vs[a][i] for i in range(3)]
                w = [vs[c][i] - vs[a][i] for i in range(3)]
                n = (u[1]*w[2]-u[2]*w[1], u[2]*w[0]-u[0]*w[2], u[0]*w[1]-u[1]*w[0])
                for i in (a, b, c):
                    for k in range(3): ns[i][k] += n[k]
                idx.extend((base + a, base + b, base + c))
            for v, n in zip(vs, ns):
                l = math.sqrt(sum(x * x for x in n)) or 1.0
                pos.extend(v); nor.extend([x / l for x in n])
        if not idx: continue
        head.append({"name": name, "nv": len(pos) // 3, "ni": len(idx), "ns": len(seg) // 3})
        blob += [pos, nor, idx, seg]
    if not head: raise RuntimeError("轉不出任何面")
    with open(OUT + ".tmp", "wb") as fh:
        fh.write(json.dumps(head).encode() + b"\n")
        for b in blob: fh.write(b.tobytes())
    os.replace(OUT + ".tmp", OUT)

try:
    main()
except BaseException as e:
    with open(OUT + ".err", "w") as fh: fh.write(str(e) or traceback.format_exc())
