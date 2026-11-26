import AppKit

// AI 操作衛星網頁（11-26 Keng：衛星 Chrome 登著我的 Google，AI 可以幫我操作，但寄信、刪檔、付款前一定先問我）。
// 衛星裡的 AI 跑 scripts/orbit-web（read／open／click／type／enter／back）⇒ 分散式通知送到這裡 ⇒ 對「這顆衛星」的網頁面板做事
// ⇒ 結果寫回 ~/Library/Caches/Orbit42/web-replies/<id>.json。
// 不給 AI 任意跑 JavaScript：只有下面幾種動作。按鈕看起來是寄出／刪除／付款類，或在非搜尋框按 Enter ⇒ 先跳視窗問 Keng，他按「允許這一次」才做。

/// 哪些動作要先問（純函式，可測）
enum WebDanger {
    static let words = [
        // 寄信／發送
        "寄出", "傳送", "送出", "發送", "發布", "發佈", "send", "post", "publish", "reply all",
        // 刪除
        "刪除", "永久刪除", "移至垃圾桶", "丟到垃圾桶", "清空", "移除", "delete", "remove", "trash", "discard", "erase", "empty",
        // 付款／購買
        "付款", "付費", "支付", "結帳", "購買", "下單", "訂購", "訂閱", "轉帳", "確認訂單", "立即購買",
        "pay", "purchase", "buy", "checkout", "check out", "place order", "confirm order", "subscribe", "transfer", "donate",
    ]

    /// 要按的東西的文字（aria-label、提示、按鈕字…）⇒ 命中的字；沒命中 nil
    static func hit(_ label: String) -> String? {
        let l = label.lowercased()
        for w in words {
            if w.unicodeScalars.allSatisfy({ $0.isASCII }) {
                // 英文：要整個字（不然 "repost"、"payload"、"buyer guide" 也算）
                let pattern = "(^|[^a-z])" + NSRegularExpression.escapedPattern(for: w) + "($|[^a-z])"
                if l.range(of: pattern, options: .regularExpression) != nil { return w }
            } else if l.contains(w) { return w }
        }
        return nil
    }

    /// 在輸入框按 Enter：搜尋框以外都先問（Enter 常常就是送出表單、寄出訊息）
    static func enterNeedsAsk(search: Bool) -> Bool { !search }
}

@MainActor
final class WebAgent {
    static let shared = WebAgent()
    /// 測試的 Orbit42（ORBIT_OFFSCREEN）聽另一個名字：不然正式 App 和測試程式會互相收到對方的請求
    static var note: Notification.Name { Notification.Name("ai.okle42.orbit42.web" + (ProcessInfo.processInfo.environment["ORBIT_OFFSCREEN"] != nil ? ".test" : "")) }
    static var replyDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit42/web-replies") }
    /// 測試：ORBIT_TEST_WEB_CONFIRM=allow／deny ⇒ 不跳視窗，直接當成這個答案
    var autoAnswer = ProcessInfo.processInfo.environment["ORBIT_TEST_WEB_CONFIRM"]

    func start() {
        try? FileManager.default.createDirectory(at: Self.replyDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        DistributedNotificationCenter.default().addObserver(forName: Self.note, object: nil, queue: .main) { n in
            let u = n.userInfo as? [String: Any] ?? [:]
            let req = n.object as? String ?? ""
            MainActor.assumeIsolated { WebAgent.shared.handle(id: req, u) }
        }
    }

    // MARK: 收請求
    func handle(id: String, _ u: [String: Any]) {
        guard id.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil else { return }      // 回覆檔名只准這些字
        let op = u["op"] as? String ?? "", arg = u["arg"] as? String ?? "", text = u["text"] as? String ?? ""
        let sat = OrbitWindow.shared.pickSat(sat: u["sat"] as? String ?? "", job: u["job"] as? String ?? "")
        func done(_ ok: Bool, _ out: String) { reply(id, ok, out) }
        guard let sat else { return done(false, "找不到這顆衛星（要在 Orbit42 的衛星裡跑）") }
        if op == "open" {
            guard let url = WebPane.parse(arg), !url.isFileURL else { return done(false, "網址看不懂：\(arg)") }
            OrbitWindow.shared.openWeb(url, sat: sat)
            return after(3) { done(true, "已在這顆衛星打開 \(url.absoluteString)（等一下再 read 看內容）") }
        }
        guard let pane = OrbitWindow.shared.moonViews(sat)["web"] as? WebPane else { return done(false, "這顆衛星還沒有網頁，先跑：orbit-web open <網址>") }
        let web = pane.web
        guard web.agentReady else { return done(false, "網頁還在開，等一下再試") }
        switch op {
        case "read": js(web, Self.readJS) { r in done(r != nil, r ?? "讀不到網頁") }
        case "back": web.go(-1); after(1.5) { done(true, "已上一頁") }
        case "click":
            guard let n = Int(arg) else { return done(false, "用法：orbit-web click <編號>（編號從 read 來）") }
            js(web, Self.describeJS(n)) { r in
                guard let d = r.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }), d["missing"] == nil else {
                    return done(false, "找不到第 \(n) 個（先 read 一次拿新編號）")
                }
                let label = d["label"] as? String ?? "", host = d["host"] as? String ?? ""
                let go = { self.js(web, Self.clickJS(n)) { _ in self.after(1.5) { done(true, "已按第 \(n) 個「\(label.prefix(40))」") } } }
                if let w = WebDanger.hit(label) {
                    self.ask(what: "按「\(label.prefix(60))」", why: "看起來是「\(w)」類的動作", host: host, sat: sat) { ok in ok ? go() : done(false, "Keng 沒有同意，沒有按") }
                } else { go() }
            }
        case "type":
            guard let n = Int(arg), !text.isEmpty else { return done(false, "用法：orbit-web type <編號> <文字>") }
            js(web, Self.focusJS(n)) { r in
                guard r == "ok" else { return done(false, "找不到第 \(n) 個輸入框（先 read 一次）") }
                web.agentCmd("Input.insertText", ["text": text]) { _ in done(true, "已在第 \(n) 個打字（\(text.count) 字）") }
            }
        case "enter":
            js(web, Self.focusedJS) { r in
                let d = r.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                let search = d["search"] as? Bool ?? false, host = d["host"] as? String ?? ""
                let go = {
                    for t in ["keyDown", "keyUp"] { web.agentCmd("Input.dispatchKeyEvent", ["type": t, "key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": t == "keyDown" ? "\r" : ""]) }
                    self.after(1.5) { done(true, "已按 Enter") }
                }
                if WebDanger.enterNeedsAsk(search: search) {
                    self.ask(what: "在「\((d["label"] as? String ?? "輸入框").prefix(40))」按 Enter", why: "不是搜尋框，按 Enter 可能會送出", host: host, sat: sat) { ok in ok ? go() : done(false, "Keng 沒有同意，沒有按 Enter") }
                } else { go() }
            }
        default: done(false, "不認得的動作：\(op)（read／open／click／type／enter／back）")
        }
    }

    // MARK: 問 Keng
    private var asking = false
    func ask(what: String, why: String, host: String, sat: String, _ answer: @escaping (Bool) -> Void) {
        // 11-26 Keng：視窗要寫畫面上看得到的衛星標題（例如「修改 · Orbit42 | YouTube 驗證」），不是程式內部名「Claude 2」
        let shown = OrbitWindow.shared.satWins[sat]?.titleLabel.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        let name = shown.isEmpty ? (OrbitWindow.shared.host.satName(sat) ?? sat) : shown
        if let a = autoAnswer { print("web-agent ask: \(what)｜\(why)｜\(host)｜衛星 \(name) ⇒ 自動回答 \(a)"); fflush(stdout); return answer(a == "allow") }
        guard !asking else { return answer(false) }                     // 一次只問一件：上一個還沒答，這個直接不做
        asking = true
        let alert = NSAlert()
        alert.messageText = "衛星「\(name)」裡的 AI 想要\(what)"
        alert.informativeText = "網站：\(host.isEmpty ? "（不明）" : host)\n\(why)。用的是你登入的帳號，按下去就是你本人做的。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "不要")                              // 預設＝不要（按 Enter 不會誤允許）
        alert.addButton(withTitle: "允許這一次")
        var finished = false
        let finish: (Bool) -> Void = { ok in if finished { return }; finished = true; self.asking = false; answer(ok) }
        after(120) { if !finished { NSApp.abortModal(); alert.window.orderOut(nil); finish(false) } }      // 兩分鐘沒答＝不要
        NSApp.activate(ignoringOtherApps: true)
        if let w = OrbitWindow.shared.window, w.isVisible {
            alert.beginSheetModal(for: w) { r in finish(r == .alertSecondButtonReturn) }
        } else { finish(alert.runModal() == .alertSecondButtonReturn) }
    }

    // MARK: 工具
    private func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
    private func js(_ web: ChromeView, _ code: String, _ done: @escaping (String?) -> Void) {
        web.agentCmd("Runtime.evaluate", ["expression": code, "returnByValue": true]) { r in
            let v = ((r["result"] as? [String: Any])?["result"] as? [String: Any])?["value"]
            DispatchQueue.main.async { done(v.map { "\($0)" }) }
        }
    }
    private func reply(_ id: String, _ ok: Bool, _ out: String) {
        let f = Self.replyDir.appendingPathComponent(id + ".json"), tmp = Self.replyDir.appendingPathComponent(id + ".tmp")
        guard let d = try? JSONSerialization.data(withJSONObject: ["ok": ok, "out": out]) else { return }
        try? d.write(to: tmp); try? FileManager.default.moveItem(at: tmp, to: f)
    }

    // MARK: 網頁裡跑的固定程式（AI 不能改）
    static let readJS = """
    (()=>{const vis=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight*3&&getComputedStyle(e).visibility!=='hidden'};
    document.querySelectorAll('[data-orbit-n]').forEach(e=>e.removeAttribute('data-orbit-n'));let n=0;const items=[];
    for(const e of document.querySelectorAll('a[href],button,input,textarea,select,[role=button],[role=link],[role=menuitem],[role=tab],[role=checkbox],[role=option],[contenteditable=true]')){
      if(!vis(e)||e.type==='hidden')continue;if(n>=150)break;n++;e.setAttribute('data-orbit-n',n);
      const lab=(e.getAttribute('aria-label')||e.getAttribute('data-tooltip')||e.getAttribute('title')||e.innerText||e.value||e.getAttribute('placeholder')||e.getAttribute('name')||'').replace(/\\s+/g,' ').trim().slice(0,80);
      items.push(n+'. ['+(e.getAttribute('role')||e.tagName.toLowerCase())+(e.tagName==='INPUT'?':'+(e.type||'text'):'')+'] '+lab)}
    const text=(document.body?document.body.innerText:'').replace(/\\n{3,}/g,'\\n\\n').slice(0,6000);
    return '標題：'+document.title+'\\n網址：'+location.href+'\\n\\n'+text+'\\n\\n── 可以操作的（orbit-web click／type 用編號）──\\n'+items.join('\\n')})()
    """
    static func describeJS(_ n: Int) -> String {
        """
        (()=>{const e=document.querySelector('[data-orbit-n="\(n)"]');if(!e)return JSON.stringify({missing:true});
        const f=e.closest('form');const parts=[e.getAttribute('aria-label'),e.getAttribute('data-tooltip'),e.getAttribute('title'),e.innerText,e.value,e.getAttribute('name'),e.id];
        if(f&&(e.type==='submit'||(e.tagName==='BUTTON'&&!e.getAttribute('type'))))parts.push(f.getAttribute('aria-label'),f.getAttribute('action'));
        return JSON.stringify({label:parts.filter(Boolean).join(' ').replace(/\\s+/g,' ').trim().slice(0,200),host:location.host})})()
        """
    }
    static func clickJS(_ n: Int) -> String {
        "(()=>{const e=document.querySelector('[data-orbit-n=\"\(n)\"]');if(!e)return 'missing';e.scrollIntoView({block:'center'});e.click();return 'ok'})()"
    }
    static func focusJS(_ n: Int) -> String {
        "(()=>{const e=document.querySelector('[data-orbit-n=\"\(n)\"]');if(!e)return 'missing';e.scrollIntoView({block:'center'});e.focus();return document.activeElement===e||e.contains(document.activeElement)?'ok':'nofocus'})()"
    }
    static let focusedJS = """
    (()=>{const e=document.activeElement||document.body;const r=(e.getAttribute&&e.getAttribute('role'))||'';
    const search=e.type==='search'||r==='searchbox'||r==='combobox'||['q','search','search_query','query'].includes(e.name||'')||!!(e.closest&&e.closest('form[role=search],[role=search]'));
    return JSON.stringify({search,host:location.host,label:((e.getAttribute&&(e.getAttribute('aria-label')||e.getAttribute('placeholder')))||e.name||e.tagName||'').slice(0,60)})})()
    """
}
