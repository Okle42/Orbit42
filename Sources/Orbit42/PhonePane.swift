import AppKit
import SceneKit

/// 給 iPhone 的面板內容（11-24 Keng「手機也做：衛星頁加 3D／網頁切換」）。
/// 走手機本來就在用的 /api/sat（Tailscale＋token），不另開端點：id＝"pane|<衛星>|list"／"pane|<衛星>|3d"。
/// 只拿得到「Mac 上這顆衛星現在開著的面板」，手機不能指定檔案路徑。
/// 3D 一律攤平成同一種格式（第一行 JSON，後面 float32／uint32），手機端一個讀法就夠；貼圖不帶，只帶顏色。
enum PhoneMesh {
    static let maxBytes = 40 * 1024 * 1024
    static func pack(_ top: SCNNode) -> Data? {
        var heads: [[String: Any]] = [], blob = Data()
        func floats(_ s: SCNGeometrySource) -> [SIMD3<Float>]? {
            guard s.usesFloatComponents, s.componentsPerVector >= 3, s.bytesPerComponent == 4 || s.bytesPerComponent == 8 else { return nil }
            let d = s.data, wide = s.bytesPerComponent == 8
            guard s.vectorCount == 0 || s.dataOffset + (s.vectorCount - 1) * s.dataStride + 3 * s.bytesPerComponent <= d.count else { return nil }
            return d.withUnsafeBytes { b in (0..<s.vectorCount).map { i in
                let o = s.dataOffset + i * s.dataStride
                func f(_ k: Int) -> Float { wide ? Float(b.loadUnaligned(fromByteOffset: o + k * 8, as: Double.self)) : b.loadUnaligned(fromByteOffset: o + k * 4, as: Float.self) }
                return SIMD3(f(0), f(1), f(2))
            } }
        }
        func indices(_ e: SCNGeometryElement) -> [UInt32] {
            let d = e.data, w = e.bytesPerIndex, n = w == 0 ? 0 : d.count / w
            return d.withUnsafeBytes { b in (0..<n).map { i in
                w == 4 ? b.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) : w == 2 ? UInt32(b.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) : UInt32(b[i])
            } }
        }
        func raw<T>(_ a: [T]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }
        func flat(_ a: [SIMD3<Float>]) -> Data { raw(a.flatMap { [$0.x, $0.y, $0.z] }) }
        func color(_ m: SCNMaterial?) -> [Double] {
            guard let c = (m?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB) else { return [0.7, 0.7, 0.7] }
            return [c.redComponent, c.greenComponent, c.blueComponent].map(Double.init)
        }
        func add(_ name: String, _ col: [Double], _ pos: [SIMD3<Float>], _ nor: [SIMD3<Float>]?, _ tri: [UInt32], _ lines: [SIMD3<Float>]) {
            var p = pos, n = nor ?? [], t = tri
            if n.count != p.count {                      // 沒有法線：每個三角形自己一份
                p = tri.map { pos[Int($0)] }; t = Array(0..<UInt32(p.count)); n = []
                for i in stride(from: 0, to: p.count - 2, by: 3) {
                    let c = simd_cross(p[i + 1] - p[i], p[i + 2] - p[i]), l = simd_length(c), u = l > 0 ? c / l : SIMD3(0, 1, 0)
                    n += [u, u, u]
                }
            }
            heads.append(["name": name, "color": col, "nv": p.count, "ni": t.count, "ns": lines.count])
            blob += flat(p); blob += flat(n); blob += raw(t); blob += flat(lines)
        }
        top.enumerateHierarchy { node, _ in
            guard let g = node.geometry, node.name != "edges", blob.count <= maxBytes,
                  let vs = g.sources(for: .vertex).first.flatMap(floats), !vs.isEmpty else { return }
            let m = node.simdWorldTransform, q = simd_transpose(simd_inverse(m))
            let pos = vs.map { v -> SIMD3<Float> in let w = m * SIMD4(v, 1); return SIMD3(w.x, w.y, w.z) }
            let nor = g.sources(for: .normal).first.flatMap(floats).map { $0.map { v -> SIMD3<Float> in
                let w = q * SIMD4(v, 0), u = SIMD3(w.x, w.y, w.z), l = simd_length(u); return l > 0 ? u / l : u } }
            var lines: [SIMD3<Float>] = []
            if let e = node.childNodes.first(where: { $0.name == "edges" })?.geometry?.sources(for: .vertex).first.flatMap(floats) {
                lines = e.map { v in let w = m * SIMD4(v, 1); return SIMD3(w.x, w.y, w.z) }
            }
            for (i, e) in g.elements.enumerated() {
                var ix = indices(e)
                if e.primitiveType == .triangleStrip {
                    ix = ix.count < 3 ? [] : (0..<ix.count - 2).flatMap { k in k % 2 == 0 ? [ix[k], ix[k + 1], ix[k + 2]] : [ix[k + 1], ix[k], ix[k + 2]] }
                } else if e.primitiveType != .triangles { continue }
                ix.removeLast(ix.count % 3)
                guard !ix.isEmpty, ix.allSatisfy({ Int($0) < pos.count }) else { continue }
                // 共用頂點的多個材質：每塊只留自己用到的點
                var pp = pos, nn = nor
                if g.elements.count > 1 {
                    var map: [UInt32: UInt32] = [:]; pp = []; var n2: [SIMD3<Float>] = []
                    ix = ix.map { k in if let x = map[k] { return x }; let x = UInt32(pp.count); map[k] = x; pp.append(pos[Int(k)]); if let nor, nor.count == pos.count { n2.append(nor[Int(k)]) }; return x }
                    nn = n2.isEmpty ? nil : n2
                }
                add(node.name ?? "零件", color(g.materials.isEmpty ? nil : g.materials[min(i, g.materials.count - 1)]), pp, nn, ix, i == 0 ? lines : [])
            }
        }
        guard !heads.isEmpty, blob.count <= maxBytes, let h = try? JSONSerialization.data(withJSONObject: heads) else { return nil }
        return h + Data([10]) + blob
    }
}

extension OrbitWindow {
    /// 手機操作網頁（/api/input，id＝"pw-<衛星>"，內容是 JSON 動作陣列）。還沒開網頁時，只有「去某網址」會開一頁（不搶 Mac 的視窗）
    func phoneWeb(_ id: String, _ data: Data) -> Bool {
        guard host.has(id), let ops = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        if let v = moonViews(id)["web"] as? WebPane { v.web.phoneInput(ops); return true }
        guard let u = ops.first(where: { $0["k"] as? String == "nav" })?["u"] as? String, let url = WebPane.parse(u), !url.isFileURL else { return false }
        openWebQuiet(url, sat: id); return true
    }
    /// 手機問面板：回 nil＝沒有
    func phonePane(_ spec: String, from: Int, size: (cols: Int, rows: Int)? = nil) -> [String: Any]? {
        let p = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, p[0] == "pane" else { return nil }
        let m = moonViews(p[1])
        if p[2] == "list" {
            var out: [[String: Any]] = []
            if let v = m["3d"] as? ModelView {
                out.append(["kind": "3d", "title": v.url?.lastPathComponent ?? "", "ver": v.phoneVer, "size": v.phoneData?.count ?? 0,
                            "type": v.isImage ? "image" : "mesh", "info": v.baseInfo, "note": v.phoneData == nil ? (v.messageText.isEmpty ? "這個模型太大或轉不出來，請在 Mac 上看" : v.messageText) : ""])
            }
            if let v = m["web"] as? WebPane { out.append(["kind": "web", "title": v.titleText, "url": v.currentURL]) }
            return ["panes": out]
        }
        // 網頁：這頁 Chrome 的畫面（大小借 cols／rows 帶手機的點數）
        if p[2] == "web" {
            guard host.has(p[1]) else { return nil }
            guard let v = m["web"] as? WebPane else { return ["open": false] }
            var o = size.map { v.web.phoneFrame(have: from, width: $0.cols, height: $0.rows) } ?? [:]
            o["open"] = true; o["url"] = v.currentURL; o["title"] = v.titleText; o["msg"] = v.messageText
            return o
        }
        guard p[2] == "3d", let v = m["3d"] as? ModelView, let d = v.phoneData, from >= 0, from <= d.count else { return nil }
        return ["total": d.count, "from": from, "ver": v.phoneVer, "data": d.subdata(in: from..<min(d.count, from + 384 * 1024)).base64EncodedString()]
    }
}
