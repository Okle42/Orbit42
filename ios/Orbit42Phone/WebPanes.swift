import SwiftUI
import WebKit

/// App 裡帶著的網頁（Web＝ShoWork 球體、OrbitWeb＝衛星終端機）用 orbit://app/<路徑> 讀：
/// ES module 在 file:// 底下載不進來（跟 Mac main.swift WebFiles 同一招）
final class BundleFiles: NSObject, WKURLSchemeHandler {
    let root = Bundle.main.resourceURL!.standardizedFileURL
    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        let rel = task.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist)); return
        }
        let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css", "json": "application/json",
                     "png": "image/png", "svg": "image/svg+xml", "woff2": "font/woff2", "wasm": "application/wasm"]
        let resp = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": (types[file.pathExtension.lowercased()] ?? "application/octet-stream") + "; charset=utf-8"])!
        task.didReceive(resp); task.didReceive(data); task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// 網頁 → App 的訊息（WKScriptMessageHandler 會強引用 handler ⇒ 弱轉接）
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ t: any WKScriptMessageHandler) { target = t }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
}

@MainActor
func makeWeb(handler: any WKScriptMessageHandler, name: String) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(BundleFiles(), forURLScheme: "orbit")
    cfg.userContentController.add(WeakHandler(handler), name: name)
    cfg.allowsInlineMediaPlayback = true
    let w = WKWebView(frame: .zero, configuration: cfg)
    w.isOpaque = false
    w.backgroundColor = .black
    w.scrollView.backgroundColor = .black
    w.scrollView.contentInsetAdjustmentBehavior = .never
    w.scrollView.bounces = false
    w.scrollView.pinchGestureRecognizer?.isEnabled = false      // 11-24 整頁不縮放（球體捏合由網頁自己處理）
    #if DEBUG
    w.isInspectable = true
    #endif
    return w
}

func js(_ w: WKWebView?, _ fn: String, _ args: [Any]) {
    guard let w, let d = try? JSONSerialization.data(withJSONObject: args) else { return }
    w.evaluateJavaScript("\(fn) && \(fn)(...\(String(decoding: d, as: UTF8.self)))", completionHandler: nil)
}

// MARK: - 球體（跟 Mac Orbit42 同一份 sphere.html；資料每 2 秒從 Mac 拿一次）

@MainActor
final class SphereModel: NSObject, ObservableObject, WKScriptMessageHandler {
    let link: MacLink
    private(set) lazy var web: WKWebView = {
        let w = makeWeb(handler: self, name: "sphere")
        w.load(URLRequest(url: URL(string: "orbit://app/Web/sphere.html?orbit=1&phone=1")!))
        return w
    }()
    @Published var error: String?
    private var poll: Task<Void, Never>?
    private var last: Data?
    /// 點球上的衛星（Mac 上 Orbit42 開的）→ 切到那顆衛星的鏡像畫面
    var onFocus: (String) -> Void = { _ in }
    var onMoon: (String, String) -> Void = { _, _ in }
    /// Mac 的小衛星也掛到手機的球上
    func setMoons(_ sats: [Sat]) {
        var o: [String: [[String: Any]]] = [:]
        for s in sats { if let sid = s.sessionId, !s.moons.isEmpty { o[sid] = s.moons.map { ["kind": $0, "title": s.moonTitles[$0] ?? "", "on": false] } } }
        js(web, "window.karaMoons", [o])
    }

    init(link: MacLink) { self.link = link }

    /// 示範模式的假資料（名字、專案都是假的）：一個在等你回答的 session（4 選項答案卡）＋一個在工作的
    static let demoPayload = #"{"sessions":2,"five_hour":38,"seven_day":52,"five_reset":124,"seven_reset":3100,"ctx":21,"doneToday":3,"#
        + #""team":[{"name":"Demo-整理報表","status":"需要你","sessionId":"demo-a","progress":80,"doing":"整理報表","summary":"報表草稿做好了，格式有兩種寫法","#
        + #""ask":"報表要用哪一種格式？","options":["用表格版（建議）","用條列版","兩種都做","先不用，我看過再說"]},"#
        + #"{"name":"Demo-修登入頁","status":"工作中","sessionId":"demo-b","progress":40,"doing":"修登入頁"}],"runs":[],"heat":null,"paused":false,"#
        + #""disks":[{"name":"內建","used":61,"freeGB":98,"totalGB":256}]}"#

    func start() {
        if link.isDemo, poll == nil {
            last = Data(Self.demoPayload.utf8)
            poll = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let d = self.last else { return }
                self.web.evaluateJavaScript("window.karaUpdate && window.karaUpdate(\(String(decoding: d, as: UTF8.self)))", completionHandler: nil)
            }
        }
        guard poll == nil, !link.isDemo else { return }
        let api = OrbitAPI(link: link)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let d = try await api.sphere()
                    guard let self else { return }
                    self.error = nil
                    if d != self.last { self.last = d; self.web.evaluateJavaScript("window.karaUpdate && window.karaUpdate(\(String(decoding: d, as: UTF8.self)))", completionHandler: nil) }
                } catch { if NetStats.shared.down { self?.error = error.localizedDescription } }    // 偶爾失敗一次不跳紅條（下一輪就重試）
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stop() { poll?.cancel(); poll = nil }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let a = o["action"] as? String else { return }
        func toast(_ s: String) { js(web, "window.karaToast", [s]) }
        switch a {
        case "ready":
            if let last { web.evaluateJavaScript("window.karaUpdate && window.karaUpdate(\(String(decoding: last, as: UTF8.self)))", completionHandler: nil) }
        case "answer":
            guard let sid = o["sessionId"] as? String, let text = o["text"] as? String else { return }
            if link.isDemo { return toast("示範模式：不送出") }
            Task {
                do { toast(try await OrbitAPI(link: link).answer(session: sid, text: text, askId: o["askId"] as? String)) }
                catch { toast("沒送出：\(error.localizedDescription)") }
            }
        case "moon":           // 11-24 點小衛星 ⇒ 到那顆衛星的 3D／網頁
            if let sid = o["sessionId"] as? String { onMoon(sid, o["kind"] as? String ?? "3d") }
        case "theme":          // 11-24 球體換配色 ⇒ 終端機和整個 App 跟著換
            guard let n = o["name"] as? String else { return }
            Look.shared.fromSphere(mode: o["mode"] as? String ?? "auto", name: n)
        case "focus":
            if let sid = o["sessionId"] as? String { onFocus(sid) }
        case "permit", "captain", "ask", "listen", "speak", "newSatellite", "orbit", "audit", "timeline", "openBoard":
            if a != "speak" && a != "listen" { toast("這個要在 Mac 上做（手機版只能看和回答答案卡）") }
            if a == "speak" { js(web, "window.karaVoice", ["end"]) }       // 手機不出聲；網頁要收到結束才不會卡住
        default: break
        }
    }
}

struct WebBox: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

// MARK: - 衛星鏡像（照 Mac 的行列數顯示終端機，每秒拿新的輸出；11-24 起可以點、捲、打字，送回 Mac）

@MainActor
final class TermModel: NSObject, ObservableObject, WKScriptMessageHandler {
    let link: MacLink, sat: Sat
    private(set) lazy var web: WKWebView = {
        let w = makeWeb(handler: self, name: "orbit")
        let q = "term=1&mirror=1&sat=\(sat.id)&theme=\(light ? "light" : "dark")"
        w.load(URLRequest(url: URL(string: "orbit://app/OrbitWeb/index.html?" + q)!))
        paint(w)
        return w
    }()
    /// 11-24 深淺跟著智能體（Look）；終端機自己沒有切換鈕
    @Published private(set) var light: Bool = Look.shared.light
    static let lightBG = UIColor(red: 0xfb / 255, green: 0xfb / 255, blue: 0xf9 / 255, alpha: 1)
    private func paint(_ w: WKWebView) {
        let c = light ? Self.lightBG : .black
        w.backgroundColor = c; w.scrollView.backgroundColor = c
    }
    func setLight(_ l: Bool) {
        guard l != light else { return }
        light = l
        paint(web)
        js(web, "window.orbitTheme", [light ? "light" : "dark"])
        // 已經畫上去的字是照舊色票換過的顏色 ⇒ 清空、從頭重抓一次 Mac 的輸出（gen 讓正在路上的那一份作廢）
        js(web, "window.orbitReset", [sat.id]); gen += 1; offset = 0; kick = true
        if link.isDemo, ready { start() }          // 示範模式：重新印示範字
    }
    @Published var error: String?
    private var poll: Task<Void, Never>?
    private var offset = 0, ready = false, gen = 0
    private var want: (cols: Int, rows: Int)?          // 網頁量好的手機行列數（{action:"size"}）
    @Published var keyboard = false
    private var pending = Data(), sending = false, kick = false

    init(link: MacLink, sat: Sat) { self.link = link; self.sat = sat }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let a = o["action"] as? String else { return }      // 改大小不送（行列數照 Mac）
        if a == "key", let s = o["data"] as? String { return send(Data(s.utf8)) }
        if a == "size", let c = o["cols"] as? Int, let r = o["rows"] as? Int { want = (c, r); kick = true; return }
        guard a == "ready" else { return }
        ready = true
        js(web, "window.orbitSats", [[sat.json]])
        js(web, "window.orbitOpened", [sat.id])
        start()
    }

    func start() {
        guard poll == nil, ready else { return }
        if link.isDemo {
            js(web, "window.orbitMirror", [80, 24])
            let demo = "\u{1b}[32m●\u{1b}[0m 示範模式：連上 Mac 之後，這裡會即時顯示這顆衛星的終端機畫面，也可以點、捲、打字。\r\n"
            js(web, "window.orbitData", [sat.id, Data(demo.utf8).base64EncodedString()])
            return
        }
        let api = OrbitAPI(link: link), id = sat.id
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let g = self.gen
                    let r = try await api.screen(id, from: self.offset, want: self.want)
                    guard g == self.gen else { continue }          // 切深淺時已經重來，這份作廢
                    self.error = nil
                    if let size = r.size { js(self.web, "window.orbitMirror", [size.cols, size.rows]) }
                    if !r.data.isEmpty {
                        js(self.web, "window.orbitData", [id, r.data.base64EncodedString()])
                        self.offset = r.from + r.data.count
                    }
                } catch { if NetStats.shared.down { self.error = error.localizedDescription } }
                for _ in 0..<10 where !self.kick { try? await Task.sleep(for: .milliseconds(100)) }      // 剛打完字就提早拿畫面
                self.kick = false
            }
        }
    }
    func stop() { poll?.cancel(); poll = nil; if keyboard { toggleKeyboard() } }

    func toggleKeyboard() { keyboard.toggle(); js(web, "window.orbitKeyboard", [keyboard]) }

    /// 整段文字（多行用「貼上」格式，才不會每行都送出）；Enter 隔一下再送，跟文字黏在一起會被當成貼上的換行
    func sendText(_ t: String, enter: Bool) {
        let clean = String(t.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 32 && $0.value != 127) })
        send(Data((clean.contains("\n") ? "\u{1b}[200~" + clean.replacingOccurrences(of: "\n", with: "\r") + "\u{1b}[201~" : clean).utf8))
        guard enter else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while let s = self, s.sending { try? await Task.sleep(for: .milliseconds(50)) }
            self?.send(Data("\r".utf8))
        }
    }

    /// 送進 Mac 那顆衛星：40ms 內打的字合成一筆（請求一次只走一個）；送完馬上拿一次畫面，不用等滿 1 秒
    func send(_ d: Data) {
        if link.isDemo { return }
        pending.append(d)
        guard !sending else { return }
        sending = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            while let self, !self.pending.isEmpty {
                let chunk = self.pending.prefix(4096); self.pending.removeFirst(chunk.count)
                do { try await OrbitAPI(link: self.link).input(self.sat.id, Data(chunk)) }
                catch { self.error = "沒送到 Mac：\(error.localizedDescription)" }
            }
            self?.sending = false; self?.kick = true
        }
    }
}
