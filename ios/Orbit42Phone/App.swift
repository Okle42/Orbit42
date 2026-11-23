import SwiftUI
import VisionKit

/// Orbit42 iPhone App：連到 Mac 上的 Orbit42（經 Tailscale），看球體、看衛星的終端機畫面（唯讀）、回答答案卡。
/// 不能在衛星裡打字、不能開新衛星（11-23：先做「看＋回答」，打字等加了每台手機配對／撤銷／稽核再說）
@main
struct Orbit42PhoneApp: App {
    @State private var link: MacLink? = ProcessInfo.processInfo.environment["ORBIT_PHONE_DEMO"] != nil ? .demo : MacLink.load()
    @StateObject private var tailnet = Tailnet.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            Group {
                if let link { MainView(link: link) { MacLink.forget(); self.link = nil } }
                else { ConnectView { l in l.save(); self.link = l } }
            }
            .environmentObject(tailnet)
            .onAppear { if link?.isDemo != true { tailnet.start(); tailnet.watchNetwork()
                // 測試：ORBIT_PHONE_HEAL_TEST=<秒> ⇒ 幾秒後模擬「網路換了」整個重開內建 Tailscale，看會不會自己連回來
                if let t = ProcessInfo.processInfo.environment["ORBIT_PHONE_HEAL_TEST"].flatMap(Double.init) {
                    Task { try? await Task.sleep(for: .seconds(t)); tailnet.heal(reason: "測試") } } } }        // App 內建 Tailscale：一打開就上線（第一次要登入）
            .onChange(of: phase) { _, p in if p == .active { tailnet.refresh() } }
            .preferredColorScheme(.dark)
            .tint(Color(red: 0.31, green: 0.765, blue: 0.416))
        }
    }
}

// MARK: - 連線

struct ConnectView: View {
    var onLink: (MacLink) -> Void
    @EnvironmentObject var tailnet: Tailnet
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
                TailnetBox()
                Text("② 在 Mac 上連點兩下桌面的「Orbit42 手機配對」，用下面的按鈕掃跳出來的 QR code（或貼上網址）。")
                    .foregroundStyle(.secondary)
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
                    .onAppear { tailnet.start() }
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
    @EnvironmentObject var tailnet: Tailnet
    @ObservedObject private var stats = NetStats.shared
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
                if !link.isDemo, !tailnet.isRunning { TailnetBox().padding() }      // 內建 Tailscale 還沒上線（例如要重新登入）：主畫面也給登入按鈕
                else if let e = sphere.error { Banner(text: e) }
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
                        if !link.isDemo {
                            Text("連線方式：\(tailnet.route)").font(.footnote).foregroundStyle(.secondary)
                            Button { tailnet.heal(reason: "手動", force: true) } label: { Label("重新連線（連不上時按）", systemImage: "arrow.clockwise") }.font(.footnote)
                            Text("連線紀錄：成功 \(stats.ok)・失敗 \(stats.fail)" + (tailnet.heals > 0 ? "・重連 \(tailnet.heals) 次" : "") + (stats.fail > 0 ? "（最後一次：\(stats.lastError)）" : "")).font(.footnote).foregroundStyle(.secondary)
                        }
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
        catch { if NetStats.shared.down { satError = error.localizedDescription } }     // 偶爾失敗一次不換掉清單、不跳紅字
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

/// ① App 內建 Tailscale 的狀態：沒登入就給登入按鈕（開 Safari 用 okle42.ai 登入，之後會記住）
struct TailnetBox: View {
    @EnvironmentObject var tailnet: Tailnet
    @Environment(\.openURL) private var openURL
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text("① Tailscale（App 內建，不用另外開 Tailscale App）").font(.subheadline.weight(.semibold))
                switch tailnet.state {
                case .off, .starting: Text("啟動中…").foregroundStyle(.secondary)
                case .needsLogin(let url):
                    Text("第一次要登入：用 okle42.ai 帳號，登入一次就會記住。").foregroundStyle(.secondary)
                    Button { openURL(url) } label: { Label("登入 Tailscale", systemImage: "person.badge.key") }.buttonStyle(.borderedProminent)
                case .running(let ip): Text("已連上私人網路（\(ip)）").foregroundStyle(.secondary)
                case .failed(let m): Text(m).foregroundStyle(.red)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    var icon: String { if case .running = tailnet.state { return "checkmark.shield.fill" }; if case .failed = tailnet.state { return "exclamationmark.triangle.fill" }; return "network" }
    var color: Color { if case .running = tailnet.state { return .green }; if case .failed = tailnet.state { return .red }; return .secondary }
}
