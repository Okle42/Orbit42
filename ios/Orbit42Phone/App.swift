import SwiftUI
import VisionKit

/// Orbit42 iPhone App：連到 Mac 上的 Orbit42（經 Tailscale），看球體、看衛星的終端機畫面（唯讀）、回答答案卡。
/// 不能在衛星裡打字、不能開新衛星（11-23：先做「看＋回答」，打字等加了每台手機配對／撤銷／稽核再說）
@main
struct Orbit42PhoneApp: App {
    @State private var link: MacLink? = ProcessInfo.processInfo.environment["ORBIT_PHONE_DEMO"] != nil ? .demo : MacLink.load()
    var body: some Scene {
        WindowGroup {
            Group {
                if let link { MainView(link: link) { MacLink.forget(); self.link = nil } }
                else { ConnectView { l in l.save(); self.link = l } }
            }
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.31, green: 0.765, blue: 0.416))
        }
    }
}

// MARK: - 連線

struct ConnectView: View {
    var onLink: (MacLink) -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var scanning = false
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                (Text("OKLE").foregroundStyle(.white) + Text("42").foregroundStyle(.yellow) + Text("  ·  ORBIT").foregroundStyle(.secondary) + Text("42").foregroundStyle(.yellow))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).kerning(3)
                Text("連到你的 Mac").font(.largeTitle.bold())
                Text("在 Mac 的終端機跑下面這行，把印出來的網址貼到這裡（或掃它的 QR code）。手機和 Mac 都要連上 Tailscale。")
                    .foregroundStyle(.secondary)
                Text("showork web enable").font(.system(.body, design: .monospaced)).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                TextField("http://100.x.y.z:埠/?t=…", text: $text, axis: .vertical)
                    .font(.system(.callout, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button { connect(text) } label: { Label(checking ? "連線中…" : "連線", systemImage: "link") }
                        .buttonStyle(.borderedProminent).disabled(text.isEmpty || checking)
                    if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("掃 QR code", systemImage: "qrcode.viewfinder") }.buttonStyle(.bordered)
                    }
                }
                Divider().padding(.vertical, 6)
                Button("先看示範（不連線）") { onLink(.demo) }.buttonStyle(.bordered)
                Text("Orbit42 不經手你的 AI 帳號密碼：手機只看得到 Mac 上 Orbit42 的畫面，能做的只有回答答案卡。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $scanning) { QRScanner { s in scanning = false; text = s; connect(s) } }
    }

    func connect(_ s: String) {
        guard let l = MacLink.parse(s) else { error = "網址不對：要是 showork web enable 印出來的那行（http://100.… 開頭，後面帶 ?t=）"; return }
        error = nil; checking = true
        Task {
            do { _ = try await OrbitAPI(link: l).sats(); onLink(l) }
            catch { self.error = error.localizedDescription }
            checking = false
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        v.delegate = context.coordinator
        try? v.startScanning()
        return v
    }
    func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> C { C(found) }
    final class C: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void; var done = false
        init(_ f: @escaping (String) -> Void) { found = f }
        func dataScanner(_ v: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items { if let s = b.payloadStringValue, !done, MacLink.parse(s) != nil { done = true; found(s) } }
        }
    }
}

// MARK: - 主畫面

struct MainView: View {
    let link: MacLink
    var onForget: () -> Void
    @StateObject private var sphere: SphereModel
    @State private var tab = 0
    @State private var sats: [Sat] = []
    @State private var path: [Sat] = []
    @State private var satError: String?

    init(link: MacLink, onForget: @escaping () -> Void) {
        self.link = link; self.onForget = onForget
        _sphere = StateObject(wrappedValue: SphereModel(link: link))
    }

    var body: some View {
        TabView(selection: $tab) {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                WebBox(web: sphere.web)          // 避開瀏海／動態島和分頁列（球體的工具列、狀態字才不會被蓋到）
                if let e = sphere.error { Banner(text: e) }
            }
            .tabItem { Label("球體", systemImage: "circle.hexagongrid") }.tag(0)

            NavigationStack(path: $path) {
                List {
                    if let satError { Text(satError).foregroundStyle(.red).font(.callout) }
                    if sats.isEmpty && satError == nil { Text("Mac 上的 Orbit42 現在沒有開著的衛星").foregroundStyle(.secondary) }
                    ForEach(sats) { s in
                        NavigationLink(value: s) {
                            HStack {
                                Circle().fill(s.state == "busy" ? Color.green : s.state == "exited" ? .gray : .white.opacity(0.6)).frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    Text(s.name).font(.headline)
                                    Text("\(s.brainLabel) · \(stateText(s.state))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Text(link.isDemo ? "示範模式" : "已連到 \(link.host):\(link.port)").font(.footnote).foregroundStyle(.secondary)
                        Button(link.isDemo ? "連到我的 Mac" : "中斷並忘記這台 Mac", role: .destructive, action: onForget)
                    }
                }
                .navigationTitle("衛星")
                .navigationDestination(for: Sat.self) { s in TermScreen(model: TermModel(link: link, sat: s)) }
                .refreshable { await loadSats() }
            }
            .tabItem { Label("衛星", systemImage: "terminal") }.tag(1)
        }
        .task {
            sphere.start()
            // 測試：ORBIT_PHONE_TAB=sat ⇒ 一開就到衛星分頁、打開第一顆（模擬器沒辦法用指令點畫面）
            if ProcessInfo.processInfo.environment["ORBIT_PHONE_TAB"] == "sat" { await loadSats(); tab = 1; if let s = sats.first { path = [s] } }
            await satLoop()
        }
        .onAppear {
            // 點球上的 session：是 Orbit42 衛星就切過去看它的終端機
            sphere.onFocus = { sid in
                Task {
                    await loadSats()
                    if let s = sats.first(where: { $0.sessionId == sid }) { tab = 1; path = [s] }
                    else { js(sphere.web, "window.karaToast", ["這個 session 不是 Orbit42 的衛星，要在 Mac 上看"]) }
                }
            }
        }
    }

    func stateText(_ s: String) -> String { ["busy": "工作中", "open": "開著", "idle": "還沒啟動", "exited": "已結束"][s] ?? s }

    func loadSats() async {
        if link.isDemo { sats = Sat.demo; return }
        do { sats = Sat.list(try await OrbitAPI(link: link).sats()); satError = nil }
        catch { satError = error.localizedDescription }
    }
    func satLoop() async {
        while !Task.isCancelled { await loadSats(); try? await Task.sleep(for: .seconds(3)) }
    }
}

struct TermScreen: View {
    @StateObject var model: TermModel
    var body: some View {
        ZStack(alignment: .bottom) {
            WebBox(web: model.web).ignoresSafeArea(edges: .bottom)
            if let e = model.error { Banner(text: e) }
        }
        .background(Color.black)
        .navigationTitle(model.sat.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Text("唯讀").font(.caption).foregroundStyle(.secondary) } }
        .onAppear { _ = model.web; model.start() }
        .onDisappear { model.stop() }
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).padding(10).frame(maxWidth: .infinity)
            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10)).padding()
    }
}
