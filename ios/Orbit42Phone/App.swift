import SwiftUI
import VisionKit

/// Orbit42 iPhone App：連到 Mac 上的 Orbit42（經 Tailscale），看球體、看衛星的終端機畫面（可以點、捲、打字）、回答答案卡。
/// 不能開新衛星。
@main
struct Orbit42PhoneApp: App {
    @State private var link: MacLink? = ProcessInfo.processInfo.environment["ORBIT_PHONE_DEMO"] != nil ? .demo : MacLink.load()
    @StateObject private var tailnet = Tailnet.shared
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var look = Look.shared
    init() {
        // 11-24 深色白綠對調：導覽列標題（系統畫的）深色時用綠；淺色終端機頁維持系統黑字
        let title = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x4f / 255, green: 0xc3 / 255, blue: 0x6a / 255, alpha: 1) : .label }
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: title]
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: title]
    }
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
            .onChange(of: phase) { _, p in if p == .active { tailnet.refresh(); listenIfAsked() } }
            .onReceive(NotificationCenter.default.publisher(for: ListenTrigger.note)) { _ in listenIfAsked() }
            .onChange(of: link?.base) { _, _ in VoiceInput.shared.link = link?.isDemo == true ? nil : link }
            .task { VoiceInput.shared.link = link?.isDemo == true ? nil : link; listenIfAsked() }
            .modifier(LookProbe())
            .preferredColorScheme(look.scheme)       // 11-24 跟著球體的配色（自動＝跟 iPhone）
            .foregroundStyle(Color.okInk)          // 11-24 深色綠白對調：原本白的字改綠、原本綠的強調改白；灰字、黑底維持
            .tint(Color.okAccent)
        }
    }
}

/// 11-24 動作按鈕／控制中心按了「Orbit42 開始說話」：App 起來或回到前景就開始聽（等內建 Tailscale 一下）
@MainActor func listenIfAsked() {
    guard ListenTrigger.take() else { return }
    Task { try? await Task.sleep(for: .milliseconds(600)); VoiceInput.shared.start() }
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
                (Text("OKLE").foregroundStyle(Color.okInk) + Text("42").foregroundStyle(.yellow) + Text("  ·  ORBIT").foregroundStyle(.secondary) + Text("42").foregroundStyle(.yellow))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).kerning(3)
                Text("連到你的 Mac").font(.largeTitle.bold())
                TailnetBox()
                Text("② 在 Mac 上連點兩下桌面的「Orbit42 手機配對」，用下面的按鈕掃跳出來的 QR code（或貼上網址）。")
                    .foregroundStyle(.secondary)
                TextField("http://100.x.y.z:埠/?t=…", text: $text, axis: .vertical)
                    .font(.system(.callout, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
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
        .background(Color.okPaper.ignoresSafeArea())
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
    @State private var moved = Date.distantPast
    @State private var wantTab: String?

    init(link: MacLink, onForget: @escaping () -> Void) {
        self.link = link; self.onForget = onForget
        _sphere = StateObject(wrappedValue: SphereModel(link: link))
    }

    var body: some View {
        TabView(selection: $tab) {
            ZStack(alignment: .bottom) {
                Color.okPaper.ignoresSafeArea()
                WebBox(web: sphere.web)          // 避開瀏海／動態島和分頁列（球體的工具列、狀態字才不會被蓋到）
                if !link.isDemo, !tailnet.isRunning { TailnetBox().padding() }      // 內建 Tailscale 還沒上線（例如要重新登入）：主畫面也給登入按鈕
                else if let e = sphere.error { Banner(text: e) }
                if !link.isDemo { VoiceOverlay().frame(maxWidth: .infinity, alignment: .trailing) }      // 11-24 對智能體說話
            }
            .tabItem { Label("球體", systemImage: "circle.hexagongrid") }.tag(0)

            NavigationStack(path: $path) {
                List {
                    if let satError { Text(satError).foregroundStyle(.red).font(.callout) }
                    if sats.isEmpty && satError == nil { Text("Mac 上的 Orbit42 現在沒有開著的衛星").foregroundStyle(.secondary) }
                    ForEach(sats) { s in
                        NavigationLink(value: s) {
                            HStack {
                                Circle().fill(s.state == "busy" ? Color.okAccent : s.state == "exited" ? .gray : Color.okGreen).frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    if s.captain { Text("秘書").font(.headline).foregroundStyle(secretaryInk).padding(.horizontal, 8).background(Capsule().fill(secretaryColor)) }
                                    else { Text(s.head ?? s.name).font(.headline) }
                                    if let w = s.work { Text(w).font(.subheadline).foregroundStyle(w.hasPrefix("完成：") ? .secondary : .primary).lineLimit(1) }
                                    Text("\(s.brainLabel) · \(stateText(s.state))" + (s.moons.isEmpty ? "" : " · " + s.moons.map { $0 == "web" ? "網頁" : "3D" }.joined(separator: "、"))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { from, to in move(from, to) }      // 長按拖動；跟球體的戰情清單同一份順序
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
                .navigationDestination(for: Sat.self) { s in TermScreen(link: link, sat: s, want: $wantTab).id(s.id) }
                .refreshable { await loadSats() }
            }
            .tabItem { Label("衛星", systemImage: "terminal") }.tag(1)
        }
        .task {
            sphere.start()
            // 測試：ORBIT_PHONE_TAB=sat ⇒ 一開就到衛星分頁、打開第一顆（模擬器沒辦法用指令點畫面）
            if ProcessInfo.processInfo.environment["ORBIT_PHONE_TAB"] == "sat" { await loadSats(); tab = 1; wantTab = ProcessInfo.processInfo.environment["ORBIT_PHONE_PANE"]; if let s = sats.first(where: { !$0.moons.isEmpty }) ?? sats.first { path = [s] } }
            await satLoop()
        }
        .onReceive(VoiceInput.shared.$listening) { if $0 { tab = 0 } }      // 11-24 動作按鈕／控制中心開始聽 ⇒ 回球體分頁（字幕在那）
        .onAppear {
            sphere.onMoon = { sid, kind in
                Task {
                    await loadSats()
                    if let s = sats.first(where: { $0.sessionId == sid }) { wantTab = kind; tab = 1; path = [s] }
                }
            }
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

    private func move(_ from: IndexSet, _ to: Int) {
        sats.move(fromOffsets: from, toOffset: to)
        moved = Date()
        let ids = sats.compactMap(\.sessionId)
        guard !link.isDemo, !ids.isEmpty else { return }
        Task {
            do { try await OrbitAPI(link: link).order(ids) } catch { satError = "順序沒存到 Mac：\(error.localizedDescription)" }
            moved = .distantPast
        }
    }
    func loadSats() async {
        if link.isDemo { sats = Sat.demo; return }
        do {
            let l = Sat.list(try await OrbitAPI(link: link).sats())
            guard Date().timeIntervalSince(moved) > 3 else { return }        // 剛拖完、還沒存到 Mac：不要被舊順序蓋回去
            sats = l; satError = nil; sphere.setMoons(sats)
        }
        catch { if NetStats.shared.down { satError = error.localizedDescription } }     // 偶爾失敗一次不換掉清單、不跳紅字
    }
    func satLoop() async {
        while !Task.isCancelled { await loadSats(); try? await Task.sleep(for: .seconds(3)) }
    }
}

struct TermScreen: View {
    @StateObject var model: TermModel
    @StateObject var panes: PaneModel
    @StateObject private var phoneWeb = PhoneWeb()
    @State var tab = "term"
    @State private var composing = false
    @Binding var want: String?
    @ObservedObject private var look = Look.shared
    init(link: MacLink, sat: Sat, want: Binding<String?>) {
        _model = StateObject(wrappedValue: TermModel(link: link, sat: sat))
        _panes = StateObject(wrappedValue: PaneModel(link: link, sat: sat))
        _want = want
    }
    private func take() { if let w = want { tab = w; want = nil } }
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("終端機").tag("term")
                Text("3D").tag("3d")
                Text("網頁").tag("web")
            }
            .pickerStyle(.segmented).padding(.horizontal, 10).padding(.vertical, 6)
            switch tab {
            case "3d": ModelPane(model: panes)
            case "web": WebPaneView(panes: panes, model: phoneWeb)
            default:
                ZStack(alignment: .bottom) {
                    WebBox(web: model.web)
                    if let e = model.error { Banner(text: e) }
                }
                if composing { Composer(light: model.light) { t, enter in model.sendText(t, enter: enter) } close: { composing = false } }
                KeyBar(light: model.light, send: { model.send(Data($0.utf8)) })
            }
        }
        .background(model.light ? Color(uiColor: TermModel.lightBG) : Color.black)
        .overlay { if model.sat.captain {       // 跟 Mac 同款：秘書的衛星外框＋光暈
            RoundedRectangle(cornerRadius: 12).strokeBorder(secretaryColor, lineWidth: 3).shadow(color: secretaryColor.opacity(0.75), radius: 8).allowsHitTesting(false)
        } }
        .navigationTitle(model.sat.captain ? "秘書" : model.sat.head ?? model.sat.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
            if tab == "term" { Button { composing.toggle() } label: { Image(systemName: composing ? "keyboard.chevron.compact.down" : "keyboard") }
                .accessibilityLabel(composing ? "收起鍵盤" : "打字") }
        } }
        .onAppear { _ = model.web; model.setLight(look.light); take(); sync() }
        .onChange(of: want) { _, _ in take() }
        .onChange(of: tab) { _, _ in sync() }
        .onChange(of: look.light) { _, l in model.setLight(l) }      // 11-24 智能體換配色 ⇒ 終端機跟著換
        .onDisappear { model.stop(); panes.stop() }
    }
    /// 看 3D／網頁時終端機先停（Mac 那邊 5 秒後恢復自己的大小），回來再接上
    private func sync() {
        if tab == "term" { panes.stop(); model.start() } else { model.stop(); panes.start() }
    }
}

/// 11-24 Keng「手機上用語音輸入，打字會亂掉」：聽寫會邊聽邊改寫前面的字，終端機網頁（xterm）只會往後加、不會取代
/// ⇒ 改用原生輸入框，字改好才整段送進終端機。「送出」＝打進去＋Enter；「只貼上」不按 Enter（選單、補字用）
struct Composer: View {
    var light = false
    let send: (String, Bool) -> Void
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focus: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("打字或按鍵盤上的麥克風說話", text: $text, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused($focus)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(10).background(light ? Color.black.opacity(0.06) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 6) {
                Button("送出") { go(true) }.buttonStyle(.borderedProminent)
                Button("只貼上") { go(false) }.font(.caption)
            }.disabled(text.isEmpty)
        }
        .padding(.horizontal, 8).padding(.top, 6)
        .background(light ? Color(uiColor: TermModel.lightBG) : Color.black)
        .onAppear { focus = true }
    }
    private func go(_ enter: Bool) {
        focus = false                              // 先收鍵盤：聽寫／注音沒確定的字才會寫回來
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let t = text.trimmingCharacters(in: .newlines)
            guard !t.isEmpty else { return }
            send(t, enter); text = ""; focus = true
        }
    }
}

/// 11-24 手機鍵盤沒有的鍵（Claude Code 常用：Esc 中斷、方向鍵選選項、Tab、Ctrl+C）
struct KeyBar: View {
    var light = false
    let send: (String) -> Void
    private let keys: [(String, String)] = [("Esc", "\u{1b}"), ("Tab", "\t"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"),
                                            ("←", "\u{1b}[D"), ("→", "\u{1b}[C"), ("⏎", "\r"), ("^C", "\u{03}")]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.0) { k in
                Button { send(k.1) } label: {
                    Text(k.0).font(.system(.callout, design: .monospaced)).frame(maxWidth: .infinity, minHeight: 36)
                        .background(light ? Color.black.opacity(0.06) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(light ? Color.black.opacity(0.10) : Color.clear))
                }.buttonStyle(.plain).foregroundStyle(light ? Color(white: 0.07) : Color.okGreen)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6).background(light ? Color(uiColor: TermModel.lightBG) : Color.black)
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
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    var icon: String { if case .running = tailnet.state { return "checkmark.shield.fill" }; if case .failed = tailnet.state { return "exclamationmark.triangle.fill" }; return "network" }
    var color: Color { if case .running = tailnet.state { return .okAccent }; if case .failed = tailnet.state { return .red }; return .secondary }
}

/// 11-24 Okle42 深色綠白對調（跟 Mac 衛星終端機同一套）：一般字綠、強調白、次要字灰、黑底
extension Color {
    private static func pick(_ dark: UIColor, _ light: UIColor) -> Color { Color(uiColor: UIColor { $0.userInterfaceStyle == .light ? light : dark }) }
    /// 會跟深淺色變的：字（深色綠／淺色黑）、強調（深色白／淺色紅）、底
    static let okInk = pick(UIColor(red: 0x4f / 255, green: 0xc3 / 255, blue: 0x6a / 255, alpha: 1), UIColor(white: 0.08, alpha: 1))
    static let okAccent = pick(.white, UIColor(red: 0xd7 / 255, green: 0x26 / 255, blue: 0x1b / 255, alpha: 1))
    /// 麥克風鈕：深色綠、淺色紅
    static let okMic = pick(UIColor(red: 0x4f / 255, green: 0xc3 / 255, blue: 0x6a / 255, alpha: 1), UIColor(red: 0xd7 / 255, green: 0x26 / 255, blue: 0x1b / 255, alpha: 1))
    static let okPaper = pick(.black, UIColor(red: 0xfb / 255, green: 0xfb / 255, blue: 0xf9 / 255, alpha: 1))
    static let okGreen = Color(red: 0x4f / 255, green: 0xc3 / 255, blue: 0x6a / 255)
}

// 秘書：深色護眼綠 #4fc36a、淺色紅 #d7261b，跟 Mac 同款；綠底用深字
let secretaryColor = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x4f / 255, green: 0xc3 / 255, blue: 0x6a / 255, alpha: 1) : UIColor(red: 0.843, green: 0.149, blue: 0.106, alpha: 1) })
let secretaryInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.05, alpha: 1) : .white })
