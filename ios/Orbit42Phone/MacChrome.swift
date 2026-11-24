import SwiftUI
import UIKit

/// Mac 衛星裡那頁真的 Chrome（11-24 Keng「把這個手機上的 Chrome 網頁做好」）。
/// iPhone 不能嵌 Chrome ⇒ 畫面從 Mac 拿（/api/sat，id＝pane|衛星|web），點、捲、打字送回 Mac 那一頁（/api/input，id＝pw-衛星）。
/// 登入跟 Mac 衛星共用，localhost 也看得到。手機在看時 Mac 那頁換成手機寬度，離開 5 秒恢復。
@MainActor
final class MacChrome: ObservableObject {
    let link: MacLink, spec: String, target: String, isWindow: Bool
    @Published var image: UIImage?
    @Published var page = CGSize.zero           // 這張圖對應的頁面大小（點）
    @Published var text = ""                    // 網址列
    @Published var typing = false               // 正在改網址：不要被 Mac 的網址蓋掉
    @Published var title = ""
    @Published var note = ""
    @Published var isOpen: Bool?                // nil＝還不知道
    @Published var edit = ""                    // ""／text／password／select
    @Published var editN = 0
    @Published var options: [String] = []
    @Published var chosen = -1
    @Published var ask: Ask?
    @Published var wide = false
    struct Ask: Equatable { let type, text, value: String }
    /// 看網頁時，球體和衛星清單放慢（請求一次只走一個，讓畫面先走）
    static private var watching = 0
    static var live: Bool { watching > 0 }
    var size = CGSize.zero { didSet { if size != oldValue { kick = true } } }
    private var have = 0, url = "", poll: Task<Void, Never>?, sending = false, kick = false, lastEdit: Int?
    private var queue: [[String: Any]] = [], lastAsk: Ask?

    /// 衛星裡那頁 Chrome
    init(link: MacLink, sat: Sat) { self.link = link; spec = "pane|\(sat.id)|web"; target = "pw-\(sat.id)"; isWindow = false }
    /// Mac 上的一個視窗
    init(link: MacLink, window: Int) { self.link = link; spec = "mac|\(window)"; target = "mw-\(window)"; isWindow = true }

    func start() {
        guard poll == nil else { return }
        if link.isDemo { note = "示範模式沒有網頁"; return }
        Self.watching += 1; have = 0; lastEdit = nil
        poll = Task { [weak self] in
            var quiet = 0
            while !Task.isCancelled {
                guard let self else { return }
                quiet = await self.tick() ? 0 : quiet + 1
                // 畫面在動就一直拿；沒動就慢慢放慢，一有動作立刻回到最快
                let wait = quiet < 4 ? 0.05 : quiet < 20 ? 0.3 : 0.8
                let until = Date().addingTimeInterval(wait)
                while Date() < until, !self.kick, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(30)) }
                if self.kick { self.kick = false; quiet = 0 }
            }
        }
    }
    func stop() { guard poll != nil else { return }; poll?.cancel(); poll = nil; Self.watching -= 1 }

    private func tick() async -> Bool {
        guard size.width > 100, size.height > 100 else { return false }
        do {
            let o = try await OrbitAPI(link: link).webFrame(spec, have: have, size: size)
            if Task.isCancelled { return false }
            guard let open = o["open"] as? Bool else { note = "Mac 的 Orbit42 還不支援，要更新"; return false }
            isOpen = open
            guard open else { image = nil; have = 0; note = ""; title = ""; edit = ""; if !typing, !url.isEmpty { text = ""; url = "" }; return false }
            title = o["title"] as? String ?? ""; wide = o["wide"] as? Bool ?? false; note = o["msg"] as? String ?? ""
            let u = o["url"] as? String ?? ""
            if u != url { url = u; if !typing { text = u } }
            let n = o["editN"] as? Int ?? 0
            if lastEdit == nil { lastEdit = n } else if n != lastEdit {
                lastEdit = n
                let e = o["edit"] as? [String: Any] ?? [:]
                edit = e["kind"] as? String ?? ""; options = e["o"] as? [String] ?? []; chosen = e["i"] as? Int ?? -1
                editN = n
            }
            let a = (o["ask"] as? [String: Any]).map { Ask(type: $0["type"] as? String ?? "alert", text: $0["text"] as? String ?? "", value: $0["value"] as? String ?? "") }
            if a != lastAsk { lastAsk = a; ask = a }
            guard let s = o["seq"] as? Int, let b = o["data"] as? String, let d = Data(base64Encoded: b) else { return false }
            guard let img = await Task.detached(priority: .userInitiated, operation: { UIImage(data: d)?.preparingForDisplay() }).value else { return false }
            have = s; image = img; page = CGSize(width: o["w"] as? Int ?? Int(size.width), height: o["h"] as? Int ?? Int(size.height))
            return true
        } catch is CancellationError { return false }
        catch {
            if NetStats.shared.down { note = error.localizedDescription }
            try? await Task.sleep(for: .milliseconds(700))
            return false
        }
    }

    /// 送動作：捲動一直來，排隊中的合成一筆
    func act(_ o: [String: Any]) {
        if link.isDemo { return }
        if o["k"] as? String == "scroll", var l = queue.last, l["k"] as? String == "scroll" {
            for k in ["dx", "dy"] { l[k] = (l[k] as? Double ?? 0) + (o[k] as? Double ?? 0) }
            queue[queue.count - 1] = l
        } else { queue.append(o) }
        guard !sending else { return }
        sending = true
        Task {
            while !queue.isEmpty {
                let ops = Array(queue.prefix(20)); queue.removeFirst(ops.count)
                do { try await OrbitAPI(link: link).webInput(target, ops) }
                catch { note = "沒送到 Mac：\(error.localizedDescription)" }
                kick = true
            }
            sending = false
        }
    }
    func go() {
        typing = false
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { text = url; return }
        guard !t.hasPrefix("/"), !t.lowercased().hasPrefix("file:") else { note = "手機不能開 Mac 上的檔案"; return }
        // 不像網址 ⇒ 用 Google 搜尋
        let bare = t.components(separatedBy: "/")[0]
        let isAddress = !t.contains(" ") && (t.contains("://") || bare.contains(".") || bare.hasPrefix("localhost"))
        let u = isAddress ? t : "https://www.google.com/search?q=" + (t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        act(["k": "nav", "u": u])
    }
    /// 打字：太長分段（一筆上限 8 KB）
    func type(_ t: String, enter: Bool) {
        var s = Substring(t)
        while !s.isEmpty { let p = s.prefix(400); s = s.dropFirst(p.count); act(["k": "text", "t": String(p)]) }
        if enter { act(["k": "key", "n": "Enter"]) }
    }
    /// 用 iPhone 的 Chrome App 開同一個網址
    func chromeApp() {
        guard var c = URLComponents(string: url), c.scheme == "http" || c.scheme == "https" else { note = "先開一個網頁"; return }
        c.scheme = c.scheme == "http" ? "googlechrome" : "googlechromes"
        guard let g = c.url else { return }
        UIApplication.shared.open(g) { [weak self] ok in if !ok { Task { @MainActor in self?.note = "這支手機沒有裝 Chrome" } } }
    }
}

/// 畫面＋手勢：點＝點、拖＝捲（放手有慣性）、捏合＝手機這邊放大，放大時先移動畫面、到邊才捲網頁、點兩下不特別處理
struct ChromeSurface: UIViewRepresentable {
    let model: MacChrome
    let image: UIImage?, page: CGSize
    func makeUIView(context: Context) -> ChromeTouch { ChromeTouch(model) }
    func updateUIView(_ v: ChromeTouch, context: Context) { v.show(image, page) }
}

final class ChromeTouch: UIView, UIGestureRecognizerDelegate {
    private let model: MacChrome
    private let pic = UIImageView()
    private var page = CGSize.zero, zoom: CGFloat = 1, off = CGPoint.zero, glide: CADisplayLink?, speed = CGPoint.zero, at = CGPoint.zero
    init(_ m: MacChrome) {
        model = m
        super.init(frame: .zero)
        clipsToBounds = true; pic.contentMode = .scaleToFill; pic.layer.anchorPoint = .zero; addSubview(pic)
        let t = UITapGestureRecognizer(target: self, action: #selector(tap)); addGestureRecognizer(t)
        if m.isWindow {        // 長按＝右鍵；點兩下＝打開
            let l = UILongPressGestureRecognizer(target: self, action: #selector(long)); addGestureRecognizer(l)
            let d = UITapGestureRecognizer(target: self, action: #selector(twice)); d.numberOfTapsRequired = 2; addGestureRecognizer(d); t.require(toFail: d)
        }
        let p = UIPanGestureRecognizer(target: self, action: #selector(pan)); p.maximumNumberOfTouches = 2; p.delegate = self; addGestureRecognizer(p)
        let z = UIPinchGestureRecognizer(target: self, action: #selector(pinch)); z.delegate = self; addGestureRecognizer(z)
    }
    required init?(coder: NSCoder) { fatalError() }
    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
    override func layoutSubviews() { super.layoutSubviews(); place(); settle?.cancel()
        // 鍵盤升降會連著改大小（打字列送出時會收一下鍵盤）⇒ 停 0.5 秒才叫 Mac 換
        let s = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded()), first = model.size == .zero
        guard s.width > 0 else { return }
        settle = Task { [model] in if !first { try? await Task.sleep(for: .milliseconds(500)) }; if !Task.isCancelled { model.size = s } }
    }
    private var settle: Task<Void, Never>?
    override func willMove(toWindow w: UIWindow?) { super.willMove(toWindow: w); if w == nil { glide?.invalidate(); glide = nil } }
    func show(_ i: UIImage?, _ p: CGSize) { pic.image = i; page = p; place() }
    /// 圖照頁面的點數畫（鍵盤剛升起、Mac 還沒換大小時不要壓扁）
    private var fit: CGFloat { page.width > 0 ? min(bounds.width / page.width, model.isWindow && page.height > 0 ? bounds.height / page.height * 3 : .infinity) : 1 }
    private func place() {
        let w = page.width > 0 ? page.width * fit * zoom : bounds.width * zoom, h = page.height * fit * zoom
        off.x = min(max(off.x, 0), max(w - bounds.width, 0)); off.y = min(max(off.y, 0), max(h - bounds.height, 0))
        pic.bounds = CGRect(x: 0, y: 0, width: w, height: h); pic.layer.position = CGPoint(x: -off.x, y: -off.y)
    }
    private func onPage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x + off.x) / zoom / fit, y: (p.y + off.y) / zoom / fit) }
    @objc private func tap(_ g: UITapGestureRecognizer) {
        if glide != nil { stopGlide(); return }           // 還在滑：點一下先停
        let p = onPage(g.location(in: self))
        guard p.y <= page.height else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        model.act(["k": "tap", "x": Double(p.x), "y": Double(p.y)])
    }
    @objc private func long(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = onPage(g.location(in: self))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.act(["k": "right", "x": Double(p.x), "y": Double(p.y)])
    }
    @objc private func twice(_ g: UITapGestureRecognizer) {
        let p = onPage(g.location(in: self))
        model.act(["k": "double", "x": Double(p.x), "y": Double(p.y)])
    }
    /// 手指移動 d（點）：放大時先移動畫面，多的才捲網頁
    private func move(_ d: CGPoint) {
        let old = off
        off.x -= d.x; off.y -= d.y; place()
        let rest = CGPoint(x: -d.x - (off.x - old.x), y: -d.y - (off.y - old.y))
        guard abs(rest.x) > 0.01 || abs(rest.y) > 0.01 else { return }
        model.act(["k": "scroll", "x": Double(at.x), "y": Double(at.y), "dx": Double(rest.x / zoom / fit), "dy": Double(rest.y / zoom / fit)])
    }
    @objc private func pan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: stopGlide(); at = onPage(g.location(in: self)); fallthrough
        case .changed:
            let t = g.translation(in: self); g.setTranslation(.zero, in: self)
            if t != .zero { move(t) }
        case .ended:
            speed = g.velocity(in: self)
            guard g.numberOfTouches < 2, hypot(speed.x, speed.y) > 250 else { return }
            let l = CADisplayLink(target: self, selector: #selector(roll)); l.add(to: .main, forMode: .common); glide = l
        default: break
        }
    }
    @objc private func roll(_ l: CADisplayLink) {
        let dt = CGFloat(l.targetTimestamp - l.timestamp)
        move(CGPoint(x: speed.x * dt, y: speed.y * dt))
        let k = pow(0.05, dt); speed.x *= k; speed.y *= k
        if hypot(speed.x, speed.y) < 30 { stopGlide() }
    }
    private func stopGlide() { glide?.invalidate(); glide = nil }
    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        stopGlide()
        let c = g.location(in: self), z = min(max(zoom * g.scale, 1), 5), k = z / zoom
        g.scale = 1
        off = CGPoint(x: (off.x + c.x) * k - c.x, y: (off.y + c.y) * k - c.y); zoom = z; place()
    }
}

struct WebPaneView: View {
    @ObservedObject var model: MacChrome
    @State private var composing = false
    @State private var secret = ""
    @State private var picking = false
    @State private var reply = ""
    @FocusState private var addressFocus: Bool
    var body: some View {
        VStack(spacing: 0) {
            if !model.isWindow { HStack(spacing: 12) {
                Button { model.act(["k": "back"]) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一頁")
                Button { model.act(["k": "forward"]) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一頁")
                TextField("網址或搜尋", text: $model.text).textFieldStyle(.roundedBorder).font(.footnote).focused($addressFocus)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch).submitLabel(.go).onSubmit { model.go() }
                    .onChange(of: addressFocus) { _, f in
                        model.typing = f
                        if f { composing = false; DispatchQueue.main.async { UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil) } }
                    }
                Button { model.act(["k": "reload"]) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新載入")
                Button { composing.toggle() } label: { Image(systemName: composing ? "keyboard.chevron.compact.down" : "keyboard") }.accessibilityLabel(composing ? "收起鍵盤" : "打字")
                Button { model.chromeApp() } label: { Image(systemName: "arrow.up.forward.app") }.accessibilityLabel("用 iPhone 的 Chrome 開")
            }.padding(8) }
            else { HStack {
                Text(model.title).font(.footnote).lineLimit(1)
                Spacer()
                Button { composing.toggle() } label: { Image(systemName: composing ? "keyboard.chevron.compact.down" : "keyboard") }.accessibilityLabel(composing ? "收起鍵盤" : "打字")
            }.padding(8) }
            ZStack {
                Color.white
                ChromeSurface(model: model, image: model.image, page: model.page)
                if model.isOpen == false, model.isWindow { Text("這個視窗已經關了").font(.callout).foregroundStyle(.gray) }
                else if model.isOpen == false, model.note.isEmpty {
                    Text("這顆衛星還沒開網頁\n在上面輸入網址，Mac 的 Chrome 就會打開").font(.callout).foregroundStyle(.gray).multilineTextAlignment(.center).padding(30)
                } else if model.image == nil, model.note.isEmpty { ProgressView("從 Mac 拿畫面").tint(.gray).foregroundStyle(.gray) }
                if model.wide, model.image != nil {
                    Button("換手機版") { model.act(["k": "reload"]) }.font(.footnote).buttonStyle(.borderedProminent).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(12)
                }
                if !model.note.isEmpty { Text(model.note).font(.callout).multilineTextAlignment(.center).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 10)).padding().allowsHitTesting(false) }
            }
            if composing {
                if model.edit == "password" {
                    HStack {
                        SecureField("密碼", text: $secret).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { sendSecret() }
                        Button("送出") { sendSecret() }.buttonStyle(.borderedProminent).disabled(secret.isEmpty)
                    }.padding(8)
                } else {
                    Composer(light: Look.shared.light, enterTitle: "送出", pasteTitle: "只填入") { t, enter in model.type(t, enter: enter) } close: { composing = false }
                }
                HStack(spacing: 6) {
                    ForEach([("⌫", "Backspace"), ("Tab", "Tab"), ("Esc", "Escape"), ("↑", "ArrowUp"), ("↓", "ArrowDown"), ("←", "ArrowLeft"), ("→", "ArrowRight"), ("⏎", "Enter")], id: \.1) { t, n in
                        Button { model.act(["k": "key", "n": n]) } label: { Text(t).font(.callout.monospaced()).frame(maxWidth: .infinity, minHeight: 34).background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        // 點到網頁的輸入框 ⇒ 自動打開打字列；點到別的地方就收起來
        .onChange(of: model.editN) { _, _ in
            secret = ""
            switch model.edit {
            case "select": composing = false; picking = true
            case "text", "password": if !addressFocus { composing = true }
            default: composing = false
            }
        }
        .sheet(isPresented: $picking) {
            List(Array(model.options.enumerated()), id: \.0) { i, t in
                Button { model.act(["k": "pick", "i": i]); picking = false } label: { HStack { Text(t.isEmpty ? "（空白）" : t); Spacer(); if i == model.chosen { Image(systemName: "checkmark") } } }
            }.presentationDetents([.medium, .large])
        }
        .alert("網頁訊息", isPresented: Binding(get: { model.ask != nil }, set: { if !$0 { model.ask = nil } }), presenting: model.ask) { a in
            if a.type == "prompt" { TextField("", text: $reply) }
            Button("好") { model.act(["k": "answer", "ok": true, "t": reply]) }
            if a.type != "alert" { Button("取消", role: .cancel) { model.act(["k": "answer", "ok": false]) } }
        } message: { a in Text(a.type == "beforeunload" ? "要離開這一頁嗎？" : a.text) }
        .onChange(of: model.ask) { _, a in if let a { reply = a.value } }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
    private func sendSecret() { guard !secret.isEmpty else { return }; model.type(secret, enter: true); secret = "" }
}
