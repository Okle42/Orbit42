import SwiftUI
import SceneKit

/// Mac 上這顆衛星開著的 3D／圖片（網頁在 MacChrome.swift；11-24 Keng「手機直接轉 3D、開網頁」）。內容從 Mac 的 /api/sat 拿（id＝pane|衛星|…）
@MainActor
final class PaneModel: ObservableObject {
    let link: MacLink, sat: Sat
    @Published var scene: SCNScene?
    @Published var radius: Float = 1
    @Published var image: UIImage?
    @Published var title = ""
    @Published var info = ""
    @Published var note = ""
    @Published var loading: Double?          // 0…1 下載中
    private var ver = -1, poll: Task<Void, Never>?

    init(link: MacLink, sat: Sat) { self.link = link; self.sat = sat }

    func start() {
        guard poll == nil else { return }
        if link.isDemo { note = "示範模式沒有 3D 檔"; return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func stop() { poll?.cancel(); poll = nil; loading = nil }

    private func tick() async {
        let api = OrbitAPI(link: link)
        guard let list = try? await api.panes(sat.id) else { if scene == nil, image == nil { note = "Mac 那邊還不支援，或連不上" }; return }
        guard let p = list.first(where: { $0["kind"] as? String == "3d" }) else {
            scene = nil; image = nil; title = ""; info = ""; ver = -1; note = "Mac 上這顆衛星還沒開 3D 或圖片"; return
        }
        title = p["title"] as? String ?? ""; info = p["info"] as? String ?? ""
        let v = p["ver"] as? Int ?? 0, total = p["size"] as? Int ?? 0
        if let n = p["note"] as? String, !n.isEmpty { scene = nil; image = nil; ver = -1; note = n; return }
        guard v != ver, total > 0 else { return }
        var d = Data(); loading = 0
        defer { loading = nil }
        while d.count < total {
            if Task.isCancelled { return }
            guard let r = try? await api.paneChunk(sat.id, from: d.count), r.ver == v, !r.data.isEmpty else { return }     // 斷線或 Mac 換了檔：下一輪重來
            d += r.data; loading = Double(d.count) / Double(total)
        }
        note = ""
        if p["type"] as? String == "image" {
            scene = nil; image = UIImage(data: d)
            if image == nil { note = "手機看不了這種圖片格式" }
        } else {
            image = nil
            let blob = d
            if let m = await Task.detached(priority: .userInitiated, operation: { PhoneScene.build(blob) }).value { scene = m.scene; radius = m.radius }
            else { scene = nil; note = "模型資料壞掉" }
        }
        ver = v
    }
}

/// Mac 攤平好的網格 → SceneKit（已經置中、Y 朝上）
enum PhoneScene {
    struct Built: @unchecked Sendable { let scene: SCNScene; let radius: Float }
    private struct Head: Decodable { let name: String; let color: [Double]; let nv, ni, ns: Int }
    static func build(_ d: Data) -> Built? {
        guard let nl = d.firstIndex(of: 10), let heads = try? JSONDecoder().decode([Head].self, from: d[d.startIndex..<nl]) else { return nil }
        var at = nl + 1
        func take(_ n: Int) -> Data? { guard n >= 0, at + n <= d.endIndex else { return nil }; defer { at += n }; return Data(d[at..<at + n]) }
        func src(_ x: Data, _ s: SCNGeometrySource.Semantic, _ n: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: x, semantic: s, vectorCount: n, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let scene = SCNScene()
        for h in heads {
            guard h.color.count == 3, let p = take(h.nv * 12), let n = take(h.nv * 12), let i = take(h.ni * 4), let l = take(h.ns * 12) else { return nil }
            let g = SCNGeometry(sources: [src(p, .vertex, h.nv), src(n, .normal, h.nv)],
                                elements: [SCNGeometryElement(data: i, primitiveType: .triangles, primitiveCount: h.ni / 3, bytesPerIndex: 4)])
            let m = SCNMaterial()
            m.lightingModel = .blinn; m.isDoubleSided = true
            m.diffuse.contents = UIColor(red: h.color[0], green: h.color[1], blue: h.color[2], alpha: 1)
            m.specular.contents = UIColor(white: 0.25, alpha: 1)
            g.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: g))
            if h.ns > 1 {
                let ix = Array(0..<UInt32(h.ns)).withUnsafeBufferPointer { Data(buffer: $0) }
                let e = SCNGeometry(sources: [src(l, .vertex, h.ns)], elements: [SCNGeometryElement(data: ix, primitiveType: .line, primitiveCount: h.ns / 2, bytesPerIndex: 4)])
                let em = SCNMaterial(); em.lightingModel = .constant; em.diffuse.contents = UIColor(white: 0.08, alpha: 1); e.materials = [em]
                scene.rootNode.addChildNode(SCNNode(geometry: e))
            }
        }
        let (lo, hi) = scene.rootNode.boundingBox
        let x = hi.x - lo.x, y = hi.y - lo.y, z = hi.z - lo.z
        return Built(scene: scene, radius: max(sqrt(x * x + y * y + z * z) / 2, 1e-6))
    }
}

/// 單指轉、兩指移動、捏合縮放（SceneKit 內建手勢）
struct ModelBox: UIViewRepresentable {
    let scene: SCNScene, radius: Float, view: Int, light: Bool
    final class C { var scene: SCNScene?; var view = -1 }
    func makeCoordinator() -> C { C() }
    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true; v.autoenablesDefaultLighting = true; v.antialiasingMode = .multisampling4X
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {
        v.backgroundColor = light ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.16, alpha: 1)
        let c = context.coordinator
        guard c.scene !== scene || c.view != view else { return }
        c.scene = scene; c.view = view
        v.scene = scene
        let dir: [SIMD3<Float>] = [SIMD3(0.62, 0.45, 0.64), SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let k = view % 4, p = dir[k] * radius * 10
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        let w = v.bounds.width, h = v.bounds.height, asp = w > 0 && h > 0 ? Double(w / h) : 0.6
        cam.camera?.orthographicScale = Double(radius) * 1.05 / min(1, asp)
        cam.camera?.zNear = Double(radius) * 0.01; cam.camera?.zFar = Double(radius) * 100
        cam.position = SCNVector3(p.x, p.y, p.z)
        cam.look(at: SCNVector3Zero, up: k == 3 ? SCNVector3(0, 0, -1) : SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        scene.rootNode.addChildNode(cam); v.pointOfView = cam
        v.defaultCameraController.target = SCNVector3Zero
    }
}

struct ModelPane: View {
    @ObservedObject var model: PaneModel
    @ObservedObject private var look = Look.shared
    @State private var view = 0
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                (look.light ? Color(white: 0.95) : Color(white: 0.16))
                if let s = model.scene { ModelBox(scene: s, radius: model.radius, view: view, light: look.light) }
                else if let i = model.image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: i).resizable().scaledToFit().frame(width: UIScreen.main.bounds.width * zoom)
                    }.gesture(MagnifyGesture().onChanged { zoom = min(max($0.magnification, 0.5), 6) })
                }
                if let l = model.loading { VStack { ProgressView(value: l).frame(width: 160); Text("從 Mac 拿 \(Int(l * 100))%").font(.footnote) } }
                else if !model.note.isEmpty { Text(model.note).font(.callout).multilineTextAlignment(.center).padding(30) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(model.info).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if model.scene != nil {
                    HStack { ForEach(Array(["等角", "前", "右", "上"].enumerated()), id: \.0) { i, t in
                        Button(t) { view = i + (view / 4 + 1) * 4 }.buttonStyle(.bordered).controlSize(.small)      // 同一顆再按一次也要回正
                    } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
}
