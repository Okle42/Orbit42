import AppKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import UniformTypeIdentifiers

/// 3D 檔案怎麼讀：系統本來就會的直接開；CAD 走 FreeCAD、GLB／FBX／blend 走 Blender（都是本機無頭轉檔，原檔只讀）
enum ModelLoader {
    static let native: Set<String> = ["stl", "obj", "ply", "usd", "usda", "usdc", "usdz", "abc", "dae", "scn"]
    static let cad: Set<String> = ["step", "stp", "iges", "igs", "brep", "brp", "fcstd", "3mf", "off"]
    static let blender: Set<String> = ["glb", "gltf", "fbx", "blend"]
    static let image: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tif", "tiff", "bmp", "svg", "pdf"]
    static var all: [String] { native.union(cad).union(blender).union(image).sorted() }
    /// 原廠封閉格式：講清楚要怎麼辦，不假裝打得開
    static let closed: [String: String] = ["f3d": "Fusion", "f3z": "Fusion", "sldprt": "SolidWorks", "sldasm": "SolidWorks",
                                           "ipt": "Inventor", "iam": "Inventor", "catpart": "CATIA", "prt": "NX／Creo",
                                           "3dm": "Rhino", "skp": "SketchUp", "dwg": "AutoCAD", "max": "3ds Max"]
    static func accepts(_ u: URL) -> Bool { let e = u.pathExtension.lowercased(); return all.contains(e) || closed[e] != nil }

    struct Failure: LocalizedError { let msg: String; var errorDescription: String? { msg } }
    struct Loaded { let node: SCNNode; let size: SCNVector3; let parts: Int; let triangles: Int; let unit: String }

    static let freecad = "/Applications/FreeCAD.app/Contents/Resources/bin/freecadcmd"
    static let blenderApp = "/Applications/Blender.app/Contents/MacOS/Blender"
    static var scripts: URL {
        if let p = ProcessInfo.processInfo.environment["ORBIT_CONVERT_DIR"] { return URL(fileURLWithPath: p) }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("convert")
    }

    /// 背景執行緒呼叫
    static func load(_ url: URL, started: @escaping (Process) -> Void = { _ in }) throws -> Loaded {
        let ext = url.pathExtension.lowercased()
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure(msg: "讀不到這個檔案") }
        if let app = closed[ext] { throw Failure(msg: "這是 \(app) 的封閉格式，這裡讀不了。請在原軟體另存成 STEP 再打開") }
        let root = SCNNode()
        var zUp = false, unit = ""
        if cad.contains(ext) {
            try readO42M(convert(url, ext: "o42m", tool: freecad, toolName: "FreeCAD", started: started), into: root)
            zUp = true; unit = "mm"
        } else if blender.contains(ext) {
            _ = try readScene(convert(url, ext: "usdc", tool: blenderApp, toolName: "Blender", started: started), into: root)
        } else if native.contains(ext) {
            let up = try readScene(url, into: root)
            zUp = ext == "stl" || ext == "ply" || up
        } else { throw Failure(msg: "不支援 .\(ext)") }
        var parts = 0, tris = 0
        root.enumerateHierarchy { n, _ in
            guard let g = n.geometry else { return }
            let t = g.elements.filter { [.triangles, .triangleStrip, .polygon].contains($0.primitiveType) }.reduce(0) { $0 + $1.primitiveCount }
            if t > 0 { parts += 1; tris += t }
            for m in g.materials { m.isDoubleSided = true }
        }
        guard parts > 0 else { throw Failure(msg: "檔案裡沒有可以顯示的 3D 形狀") }
        // 外框要算整棵樹：先包一層（boundingBox 含子節點）
        let holder = SCNNode(); holder.addChildNode(root)
        let (lo, hi) = holder.boundingBox
        let size = SCNVector3(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        root.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        if zUp { holder.eulerAngles.x = -.pi / 2 }
        let out = SCNNode(); out.addChildNode(holder)
        return Loaded(node: out, size: size, parts: parts, triangles: tris, unit: unit)
    }

    private static func readScene(_ url: URL, into root: SCNNode) throws -> Bool {
        let ext = url.pathExtension.lowercased()
        let scene: SCNScene; var zUp = false
        if ext == "scn" || ext == "dae" {
            scene = try SCNScene(url: url, options: nil)
        } else {
            let asset = MDLAsset(url: url)
            guard asset.count > 0 else { throw Failure(msg: "檔案是空的或格式不對") }
            zUp = asset.upAxis.z > 0.5; asset.loadTextures()
            scene = SCNScene(mdlAsset: asset)
        }
        for c in scene.rootNode.childNodes { root.addChildNode(c) }
        root.enumerateHierarchy { n, _ in n.camera = nil; n.light = nil }       // 檔案自己的鏡頭／燈不要
        return zUp
    }

    /// 轉檔結果放快取，檔案沒改過就不重轉
    private static func convert(_ url: URL, ext: String, tool: String, toolName: String, started: (Process) -> Void) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: tool) else { throw Failure(msg: "這種檔案要靠 \(toolName) 轉檔，這台電腦沒裝") }
        let at = try fm.attributesOfItem(atPath: url.path)
        let stamp = "\(url.path)|\((at[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(at[.size] ?? 0)|v2"
        var h: UInt64 = 0xcbf29ce484222325
        for b in stamp.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit42/models")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let done = dir.appendingPathComponent(String(format: "%016llx.", h) + ext)
        if fm.fileExists(atPath: done.path) { return done }
        // 先寫自己的暫存檔再改名：兩個視窗同時轉同一個檔不會讀到一半
        let tmp = dir.appendingPathComponent(UUID().uuidString + "." + ext)
        let err = URL(fileURLWithPath: tmp.path + ".err")
        defer { try? fm.removeItem(at: tmp); try? fm.removeItem(at: err) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        let script = scripts.appendingPathComponent(tool == freecad ? "cad_to_mesh.py" : "blender_to_usd.py").path
        p.arguments = tool == freecad ? [script] : ["--background", "--factory-startup", "--disable-autoexec", "--python", script]
        var env = ProcessInfo.processInfo.environment
        env["O42_IN"] = url.path; env["O42_OUT"] = tmp.path; env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); started(p)
        let limit = DispatchWorkItem { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: limit)
        p.waitUntilExit(); limit.cancel()
        if let m = try? String(contentsOf: err, encoding: .utf8) { throw Failure(msg: "轉檔失敗：\(m.prefix(300))") }
        guard fm.fileExists(atPath: tmp.path) else {
            throw Failure(msg: p.terminationReason == .uncaughtSignal ? "轉檔中斷（超過 3 分鐘或當掉）" : "\(toolName) 沒有產生結果，檔案可能損壞")
        }
        if !fm.fileExists(atPath: done.path) { try fm.moveItem(at: tmp, to: done) }
        return done
    }

    private struct Head: Decodable { let name: String; let nv, ni, ns: Int }
    private static func readO42M(_ url: URL, into root: SCNNode) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let nl = d.firstIndex(of: 10) else { throw Failure(msg: "轉檔結果壞掉") }
        let heads = try JSONDecoder().decode([Head].self, from: d[d.startIndex..<nl])
        var at = nl + 1
        func take(_ n: Int) throws -> Data {
            guard n >= 0, at + n <= d.endIndex else { throw Failure(msg: "轉檔結果不完整") }
            defer { at += n }
            return Data(d[at..<at + n])
        }
        func src(_ data: Data, _ s: SCNGeometrySource.Semantic, _ n: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: s, vectorCount: n, usesFloatComponents: true, componentsPerVector: 3,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        for (i, h) in heads.enumerated() {
            let pos = try take(h.nv * 12), nor = try take(h.nv * 12), idx = try take(h.ni * 4), seg = try take(h.ns * 12)
            let g = SCNGeometry(sources: [src(pos, .vertex, h.nv), src(nor, .normal, h.nv)],
                                elements: [SCNGeometryElement(data: idx, primitiveType: .triangles, primitiveCount: h.ni / 3, bytesPerIndex: 4)])
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = NSColor(white: [0.74, 0.66, 0.80, 0.60][i % 4], alpha: 1)
            m.specular.contents = NSColor(white: 0.25, alpha: 1)
            g.materials = [m]
            let n = SCNNode(geometry: g); n.name = h.name
            if h.ns > 0 {
                let ix = (0..<UInt32(h.ns)).map { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
                let e = SCNGeometry(sources: [src(seg, .vertex, h.ns)],
                                    elements: [SCNGeometryElement(data: ix, primitiveType: .line, primitiveCount: h.ns / 2, bytesPerIndex: 4)])
                let em = SCNMaterial(); em.lightingModel = .constant; em.diffuse.contents = NSColor(white: 0.08, alpha: 1)
                e.materials = [em]
                let en = SCNNode(geometry: e); en.name = "edges"; n.addChildNode(en)
            }
            root.addChildNode(n)
        }
    }
}

/// SceneKit 畫面：左鍵拖＝轉、右鍵拖＝平移（系統內建）、滾輪＝縮放（自己做，內建的滾輪是平移）、點＝選零件
final class ModelSceneView: SCNView {
    var onPick: (SCNNode?) -> Void = { _ in }
    private var down = NSPoint.zero
    override func scrollWheel(with e: NSEvent) {
        guard let c = pointOfView?.camera else { return }
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.004 : e.scrollingDeltaY * 0.05
        c.orthographicScale = min(max(c.orthographicScale * exp(-Double(d)), 1e-5), 1e7)
    }
    override func mouseDown(with e: NSEvent) { down = e.locationInWindow; super.mouseDown(with: e) }
    override func mouseUp(with e: NSEvent) {
        super.mouseUp(with: e)
        guard hypot(e.locationInWindow.x - down.x, e.locationInWindow.y - down.y) < 3 else { return }
        let hits = hitTest(convert(e.locationInWindow, from: nil), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        onPick(hits.map(\.node).first { $0.name != "edges" })
    }
}

/// 3D 小視窗的內容：上面一排按鈕、中間模型、下面一行資訊；外框（標題列、三顆燈）跟終端機同一個 TermWindowView
@MainActor
final class ModelView: NSView {
    let scn = ModelSceneView()
    private let info = NSTextField(labelWithString: ""), message = NSTextField(wrappingLabelWithString: "")
    private let bar = NSStackView(), files = NSPopUpButton(), shut = NSButton(title: "✕", target: nil, action: nil)
    private let flat = NSScrollView(), picture = NSImageView()
    private var viewButtons: [NSButton] = []
    private(set) var history: [URL] = []
    /// 長在衛星裡：多一顆關面板的鈕
    var onShut: (() -> Void)? { didSet { shut.isHidden = onShut == nil; fold.isHidden = onShut == nil } }
    var onTuck: () -> Void = {}
    private let fold = NSButton(title: "－", target: nil, action: nil)
    var isImage: Bool { !flat.isHidden }
    var hasPicture: Bool { picture.image != nil }
    private var root = SCNNode(), loaded: ModelLoader.Loaded?, wire = false
    private var picked: (SCNMaterial, Any?)?
    private var token = 0
    private var process: Process?
    private(set) var url: URL?
    var onTitle: (String) -> Void = { _ in }
    var onOpenPanel: () -> Void = {}
    var onLoaded: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scn.scene = SCNScene(); scn.scene?.rootNode.addChildNode(root)
        scn.backgroundColor = .clear; scn.allowsCameraControl = true; scn.autoenablesDefaultLighting = true
        scn.antialiasingMode = .multisampling4X; scn.rendersContinuously = false
        scn.onPick = { [weak self] n in self?.pick(n) }
        addSubview(scn)
        for (i, t) in ["等角", "前", "右", "上", "線框", "開啟⋯"].enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.tag = i; b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11)
            bar.addArrangedSubview(b); if i < 5 { viewButtons.append(b) }
        }
        files.font = .systemFont(ofSize: 11); files.controlSize = .small; files.target = self; files.action = #selector(again); files.isHidden = true
        shut.bezelStyle = .inline; shut.font = .systemFont(ofSize: 11); shut.target = self; shut.action = #selector(close); shut.isHidden = true
        shut.toolTip = "關掉（小衛星也不見，終端機照跑）"
        fold.bezelStyle = .inline; fold.font = .systemFont(ofSize: 11); fold.target = self; fold.action = #selector(tuckAway); fold.isHidden = true
        fold.toolTip = "收起（小衛星留著，點它叫回來）"
        bar.addArrangedSubview(fold); bar.addArrangedSubview(shut); bar.addArrangedSubview(files)
        flat.documentView = picture; flat.drawsBackground = false; flat.allowsMagnification = true
        flat.minMagnification = 0.02; flat.maxMagnification = 20; flat.hasVerticalScroller = true; flat.hasHorizontalScroller = true; flat.isHidden = true
        picture.imageScaling = .scaleNone; picture.unregisterDraggedTypes()
        addSubview(flat)
        bar.spacing = 6; addSubview(bar)
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor; info.lineBreakMode = .byTruncatingTail
        addSubview(info)
        message.alignment = .center; message.font = .systemFont(ofSize: 13); message.textColor = .labelColor
        addSubview(message)
        registerForDraggedTypes([.fileURL]); scn.unregisterDraggedTypes()
        message.stringValue = "把 3D 檔案拖進來，或按「開啟⋯」"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        bar.frame = NSRect(x: 12, y: h - 30, width: min(bar.fittingSize.width, max(0, w - 24)), height: 24)
        info.frame = NSRect(x: 12, y: 6, width: max(0, w - 40), height: 16)
        scn.frame = NSRect(x: 0, y: 26, width: w, height: max(0, h - 60))
        flat.frame = scn.frame; fitPicture()
        message.frame = NSRect(x: 30, y: h / 2 - 40, width: max(0, w - 60), height: 80)
    }
    @objc private func tap(_ b: NSButton) {
        switch b.tag {
        case 4: wire.toggle(); scn.debugOptions = wire ? [.renderAsWireframe] : []
        case 5: onOpenPanel()
        default: look(b.tag)
        }
    }

    @objc private func close() { onShut?() }
    @objc private func tuckAway() { onTuck() }
    @objc private func again() { let i = files.indexOfSelectedItem; if history.indices.contains(i) { open(history[i]) } }
    private func fitPicture() {
        guard !flat.isHidden, let s = picture.image?.size, s.width > 0, s.height > 0, flat.bounds.width > 10, flat.bounds.height > 10 else { return }
        flat.magnify(toFit: NSRect(origin: .zero, size: s))
    }
    private func openImage(_ u: URL) {
        guard let d = try? Data(contentsOf: u), let img = NSImage(data: d), img.size.width > 0 else {
            message.stringValue = "這張圖打不開（讀不到或檔案壞掉）"; onLoaded(false); return
        }
        var size = img.size                                        // 點陣圖用像素大小（DPI 標記不同也一樣大）
        if let r = img.representations.first, r.pixelsWide > 0, r.pixelsHigh > 0 { size = NSSize(width: r.pixelsWide, height: r.pixelsHigh); img.size = size }
        picture.image = img; picture.frame = NSRect(origin: .zero, size: size)
        flat.isHidden = false; message.isHidden = true; fitPicture()
        info.stringValue = "\(Int(size.width)) × \(Int(size.height))   \(u.pathExtension.uppercased())"
        onLoaded(true)
    }

    func open(_ u: URL) {
        cancel()
        url = u
        if !history.contains(u) { history.append(u) }
        files.removeAllItems()
        for h in history { files.menu?.addItem(NSMenuItem(title: h.lastPathComponent, action: nil, keyEquivalent: "")) }
        files.selectItem(at: history.firstIndex(of: u) ?? 0); files.isHidden = history.count < 2
        let img = ModelLoader.image.contains(u.pathExtension.lowercased())
        viewButtons.forEach { $0.isHidden = img }; flat.isHidden = true; picture.image = nil; scn.isHidden = img
        needsLayout = true
        let t = token
        root.childNodes.forEach { $0.removeFromParentNode() }
        loaded = nil; picked = nil
        info.stringValue = ""; message.stringValue = "正在開啟 \(u.lastPathComponent)⋯"; message.isHidden = false
        onTitle(u.lastPathComponent)
        if img { openImage(u); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Result { try ModelLoader.load(u) { p in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    if let self, self.token == t { self.process = p } else if p.isRunning { p.terminate() }
                } }
            } }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, self.token == t else { return }
                self.process = nil
                switch r {
                case .success(let l):
                    self.loaded = l; self.message.isHidden = true
                    self.root.addChildNode(l.node); self.summary(); self.look(0); self.onLoaded(true)
                case .failure(let e):
                    self.message.stringValue = e.localizedDescription; self.onLoaded(false)
                }
            } }
        }
    }
    /// 關視窗／換檔：還在轉的就停掉
    func cancel() { token += 1; if let p = process, p.isRunning { p.terminate() }; process = nil }

    var summaryText: String { info.stringValue }
    var messageText: String { message.isHidden ? "" : message.stringValue }
    private func n(_ v: CGFloat) -> String { String(format: abs(v) >= 100 ? "%.1f" : "%.3g", Double(v)) }
    private func summary() {
        guard let l = loaded else { return }
        info.stringValue = "\(n(l.size.x)) × \(n(l.size.y)) × \(n(l.size.z))\(l.unit.isEmpty ? "（檔案單位）" : " " + l.unit)   \(l.parts) 個零件   \(l.triangles) 面"
    }
    private func pick(_ node: SCNNode?) {
        if let (m, old) = picked { m.emission.contents = old; picked = nil }
        guard let node, let m = node.geometry?.firstMaterial, let l = loaded else { summary(); return }
        picked = (m, m.emission.contents)
        m.emission.contents = NSColor(srgbRed: 0.10, green: 0.35, blue: 0.16, alpha: 1)
        let (lo, hi) = node.boundingBox
        info.stringValue = "\(node.name ?? "零件")   \(n(hi.x - lo.x)) × \(n(hi.y - lo.y)) × \(n(hi.z - lo.z)) \(l.unit)"
    }
    /// 每次都換一顆新鏡頭：內建的拖曳會把鏡頭換成系統自己的，改舊的沒有用
    func look(_ k: Int) {
        guard let l = loaded else { return }
        let x = CGFloat(l.size.x), y = CGFloat(l.size.y), z = CGFloat(l.size.z)
        let r = max(sqrt(x * x + y * y + z * z) / 2, 1e-6)
        let v = [SCNVector3(0.62, 0.45, 0.64), SCNVector3(0, 0, 1), SCNVector3(1, 0, 0), SCNVector3(0, 1, 0)][k]
        let c = SCNCamera(); c.usesOrthographicProjection = true
        let asp = max(0.1, scn.bounds.width / max(1, scn.bounds.height))
        c.orthographicScale = Double(r * 1.05 / min(1, asp)); c.zNear = Double(r) * 0.01; c.zFar = Double(r) * 100
        let cam = SCNNode(); cam.camera = c
        cam.position = SCNVector3(v.x * r * 10, v.y * r * 10, v.z * r * 10)
        cam.look(at: SCNVector3Zero, up: k == 3 ? SCNVector3(0, 0, -1) : SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scn.scene?.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        scn.scene?.rootNode.addChildNode(cam); scn.pointOfView = cam
        scn.defaultCameraController.target = SCNVector3Zero
    }

    private func file(_ s: NSDraggingInfo) -> URL? {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first { ModelLoader.accepts($0) }
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { file(s) == nil ? [] : .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { guard let u = file(s) else { return false }; open(u); return true }
}

// MARK: 主視窗裡的 3D 小視窗
extension OrbitWindow {
    static let openNote = Notification.Name("ai.okle42.orbit42.open3d")
    /// ⌘O 選檔、⇧⌘O 叫回收起的 3D 視窗；scripts/orbit3d <檔案> 從終端機開
    func startModels(test: Bool) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let f = e.modifierFlags.intersection([.command, .shift, .control, .option])
            guard let self, e.window === self.window, e.charactersIgnoringModifiers?.lowercased() == "o" else { return e }
            if f == .command { self.pickModel(); return nil }
            if f == [.command, .shift] { self.recallModels(); return nil }
            return e
        }
        guard !test else { return }
        DistributedNotificationCenter.default().addObserver(forName: Self.openNote, object: nil, queue: .main) { n in
            guard let path = n.object as? String else { return }
            let sat = n.userInfo?["sat"] as? String ?? "", job = n.userInfo?["job"] as? String ?? ""
            MainActor.assumeIsolated {
                if n.userInfo?["kind"] as? String == "web" { if let u = WebPane.parse(path) { OrbitWindow.shared.openWeb(u, sat: sat, job: job) } }
                else { OrbitWindow.shared.openView(URL(fileURLWithPath: path), sat: sat, job: job) }
            }
        }
    }
    func pickModel(into v: ModelView? = nil, sat: String = "") {
        let p = NSOpenPanel()
        p.allowedContentTypes = (ModelLoader.all + Array(ModelLoader.closed.keys)).compactMap { UTType(filenameExtension: $0) }
        p.allowsMultipleSelection = v == nil; p.message = "選要檢視的 3D 檔案"
        p.beginSheetModal(for: window) { [weak self, weak v] r in
            guard r == .OK else { return }
            MainActor.assumeIsolated {
                if let v, let u = p.url { v.open(u) } else { for u in p.urls { self?.openView(u, sat: sat) } }
            }
        }
    }
}
