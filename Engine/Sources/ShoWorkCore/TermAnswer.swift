import Foundation

// 答案卡要跟在終端機打字一樣（T1125025810，11-25 Keng）：按了答案卡，完整文字貼進那個 session 的衛星終端機再按 Enter，
// 對話裡就是一般的「❯ …」。只有 Keng 在介面上按的才走這條（BoardActions.AnswerSource）。
// 寧可不打：看不準就一個字都不寫，回 notStarted，呼叫端改走原本的訊息。一旦寫了字就絕不再走訊息（不會送兩次）。
// 只在 session 閒著時打：忙的時候 Claude Code 只把它排隊，對話紀錄的排隊那行不含內容（2.1.331 實測），確認不了。

public enum TermAnswer {
    public enum Outcome: Sendable, Equatable {
        case sent                       // 對話紀錄裡看到這句了
        case sentDropped(String)        // 送到了，但你那段時間按的鍵沒補（畫面已變成選單／權限框）
        case notStarted(String)         // 一個字都沒寫；原因
        case unsure(String)             // 寫了但沒確認到；原因
    }

    /// 終端機現在的畫面：text＝整行字，solid＝拿掉淡色字（輸入框的提示字是淡色）
    public struct Screen: Sendable, Equatable, Codable {
        public struct Row: Sendable, Equatable, Codable {
            public var text: String, solid: String
            public init(text: String, solid: String) { self.text = text; self.solid = solid }
        }
        public var rows: [Row]
        public var cursorRow: Int, cursorCol: Int
        public var paste: Bool          // 程式有開 bracketed paste
        public init(rows: [Row], cursorRow: Int, cursorCol: Int, paste: Bool) { self.rows = rows; self.cursorRow = cursorRow; self.cursorCol = cursorCol; self.paste = paste }
    }

    /// 判斷用：NFKC（全形、相容字變成一般字）
    public static func norm(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces) }

    /// 要打進去的字：換行變空白、控制字元拿掉。看不見或會疊在別的字上的（零寬、變體選擇符、組合字、雙向控制）、四位元組的表情符號 ⇒ 不打（nil）：
    /// 畫面上對不起來，也能拿來躲開頭的判斷。開頭只准字母、數字、中日韓文字（先正規化再看），其他一律加「回答：」
    public static func clean(_ s: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: out.append(" "); continue
            case 0..<0x20, 0x7F..<0xA0: continue
            default: break
            }
            switch u.properties.generalCategory {
            case .format, .nonspacingMark, .enclosingMark, .spacingMark, .privateUse, .surrogate, .unassigned, .control: return nil
            default: break
            }
            if u.properties.isVariationSelector || u.properties.isDefaultIgnorableCodePoint { return nil }
            if u.value > 0xFFFF, !(0x20000...0x3FFFF).contains(u.value) { return nil }
            out.append(u)
        }
        var t = String(out).trimmingCharacters(in: .whitespaces)
        let n = norm(t)
        guard let first = n.unicodeScalars.first else { return nil }
        // 正規化之後才冒出來的組合字也不打
        if n.unicodeScalars.contains(where: { [.nonspacingMark, .enclosingMark, .spacingMark].contains($0.properties.generalCategory) }) { return nil }
        // @ 會跳檔案選單、Enter 會選到檔案 ⇒ 不打
        if n.range(of: #"(^|\s)@"#, options: .regularExpression) != nil { return nil }
        let words = ["exit", "quit", ":q", ":q!", ":wq", ":wq!"]
        if !CharacterSet.alphanumerics.contains(first) || words.contains(n.lowercased()) { t = "回答：" + t }
        if n.hasSuffix("\\") { t += "。" }          // 行尾反斜線＋Enter 會變換行
        return t
    }

    /// 輸入框：上緣「──── 名字 ─」、下緣整條線；回傳框裡每一行（去掉「❯ 」）
    static func box(_ s: Screen, name: String) -> (top: Int, lines: [String])? {
        func bar(_ t: String) -> Bool { t.count >= 20 && t.allSatisfy { $0 == "─" } }
        let rows = s.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }
        guard let b = rows.lastIndex(where: bar), let a = rows[..<b].lastIndex(where: { $0.hasPrefix("──────") }), b - a >= 2 else { return nil }
        let label = rows[a].drop { $0 == "─" }.reversed().drop { $0 == "─" }.reversed()
        guard rows[a].hasSuffix("─"), String(label).trimmingCharacters(in: .whitespaces) == name, rows[a + 1].hasPrefix("❯") else { return nil }
        // 框下面不能有選單的提示
        guard !rows[(b + 1)...].contains(where: { $0.range(of: #"(?i)esc to (cancel|close|exit|go back)|enter to|to select|to navigate"#, options: .regularExpression) != nil }) else { return nil }
        var lines = (a + 1..<b).map { s.rows[$0].solid }
        if let r = lines[0].range(of: "❯") { lines[0] = String(lines[0][r.upperBound...]) }
        return (a, lines)
    }

    /// 畫面還是這個對話的一般輸入框（不是選單、權限框）
    public static func plain(_ s: Screen, name: String) -> Bool { box(s, name: name) != nil }

    static func squash(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) })) }

    /// 可以打了嗎；不行就回原因
    public static func blocked(_ s: Screen, name: String) -> String? {
        guard s.paste else { return "還沒準備好收字" }
        guard let b = box(s, name: name) else { return "開著選單或對話框，或不是這個對話" }
        guard squash(b.lines.joined()).isEmpty else { return "輸入框有還沒送出的字" }
        guard s.cursorRow == b.top + 1, s.cursorCol <= 2 else { return "游標不在輸入框開頭" }
        return nil
    }

    /// 貼上之後：框裡就是這句（很長時 Claude Code 會收成 [Pasted text …]）
    public static func holds(_ s: Screen, name: String, text: String) -> Bool {
        guard let b = box(s, name: name) else { return false }
        let got = squash(b.lines.joined())
        return got == squash(text) || got.range(of: #"^\[Pastedtext#\d+(\+\d+lines)?\]$"#, options: .regularExpression) != nil
    }

    /// 對話紀錄新增的部分有沒有「使用者打了這句」（跨 session 訊息是包起來的，不會剛好等於）
    public static func confirmed(_ added: Data, text: String) -> Bool {
        for l in added.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any], o["type"] as? String == "user",
                  o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true, let c = (o["message"] as? [String: Any])?["content"] else { continue }
            let t = (c as? String) ?? (c as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() ?? ""
            if squash(t) == squash(text) { return true }
        }
        return false
    }

    /// 打字那段時間扣住的按鍵怎麼辦：打成功或沒打、而且畫面還是一般輸入框（safe）⇒ 原樣補回；沒確認到 ⇒ 一個都不補（Enter 會把卡片的字一起送出），但要講丟了什麼
    public static func settle(_ r: Outcome, held: Data, safe: Bool) -> (Outcome, replay: Data) {
        if case .unsure = r {} else if safe { return (r, held) }
        let s = String(decoding: held, as: UTF8.self)
        // 滑鼠、焦點、終端機自動回覆不是你打的
        let keys = s.replacingOccurrences(of: #"\x1B\[(<[0-9;]*[Mm]|[IO](?![A-Za-z])|[?>][0-9;]*[a-zA-Z]|[0-9;]*R)|\x1B[\]P][^\x07\x1B]*(\x07|\x1B\\)"#, with: "", options: .regularExpression)
        guard !keys.isEmpty else { return (r, Data()) }
        let text = keys.replacingOccurrences(of: #"\x1B(\[200~|\[201~|\[[0-9;]*[A-Za-z~]|O[A-Z])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "⏎").filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }
        let what = text.isEmpty ? "你這段時間按的鍵沒有送進去" : "你這段時間打的「\(text.prefix(200))\(text.count > 200 ? "⋯" : "")」沒有送進去，請重打"
        switch r {
        case .unsure(let why): return (.unsure(why + "；" + what), Data())
        case .notStarted(let why): return (.notStarted(why + "；" + what), Data())
        case .sent, .sentDropped: return (.sentDropped(what), Data())
        }
    }

    /// 對象現在的樣子（每次都重讀，不用快取）
    public struct Target: Sendable, Equatable {
        public var sid: String, name: String, idle: Bool, unique: Bool
        public init(sid: String, name: String, idle: Bool, unique: Bool) { self.sid = sid; self.name = name; self.idle = idle; self.unique = unique }
    }
    @MainActor
    public struct IO {
        public var target: () -> Target?
        public var screen: () async -> Screen?
        public var mark: () -> Bool                 // 貼字前寫好「這句是卡片打的」（TypedMark）；寫不進去就不打
        public var write: (Data) -> Void
        public var typing: () -> Bool               // 使用者剛剛在這個終端機按過鍵
        public var added: () -> Data?               // 對話紀錄從開始到現在新增的內容；nil＝找不到對話紀錄
        public var wait: (Double) async -> Void
        public init(target: @escaping () -> Target?, screen: @escaping () async -> Screen?, mark: @escaping () -> Bool, write: @escaping (Data) -> Void,
                    typing: @escaping () -> Bool, added: @escaping () -> Data?, wait: @escaping (Double) async -> Void) {
            self.target = target; self.screen = screen; self.mark = mark; self.write = write; self.typing = typing; self.added = added; self.wait = wait
        }
    }

    @MainActor
    public static func send(_ text: String, to sid: String, io: IO) async -> Outcome {
        func wrong(_ name: String? = nil) -> String? {
            guard let t = io.target(), t.sid == sid, name == nil || t.name == name else { return "對不上這個 session" }
            if !t.unique { return "有兩個同名的 session" }
            return t.idle ? nil : "它正在忙"
        }
        if let w = wrong() { return .notStarted(w) }
        let name = io.target()!.name
        if io.typing() { return .notStarted("你正在打字") }
        guard io.added() != nil else { return .notStarted("找不到對話紀錄") }
        // 畫面要連看兩次都一樣可以打（剛好在重畫、對話框正要跳出來的不算）
        for _ in 0..<2 {
            guard let s = await io.screen() else { return .notStarted("讀不到畫面") }
            if let b = blocked(s, name: name) { return .notStarted(b) }
            await io.wait(0.15)
        }
        if let w = wrong(name) { return .notStarted(w) }
        if io.typing() { return .notStarted("你正在打字") }
        guard io.mark() else { return .notStarted("題目已經不在了，或寫不了記號") }
        io.write(Data("\u{1B}[200~\(text)\u{1B}[201~".utf8))
        var ok = false
        for _ in 0..<15 {
            await io.wait(0.1)
            if let s = await io.screen(), holds(s, name: name, text: text) { ok = true; break }
        }
        if !ok || wrong(name) != nil {
            // 不按 Enter，也不留字：貼之前框是空的、你的按鍵扣著 ⇒ 框裡只有剛貼的；清掉而且看到真的空了，才算沒打過
            if let s = await io.screen(), box(s, name: name) != nil {
                io.write(Data([0x15]))          // Ctrl+U
                for _ in 0..<10 {
                    await io.wait(0.1)
                    if let s = await io.screen(), blocked(s, name: name) == nil { return .notStarted("貼上的字對不起來，已經清掉") }
                }
            }
            return .unsure("字可能留在輸入框，沒有按 Enter")
        }
        io.write(Data("\r".utf8))
        for _ in 0..<50 {
            await io.wait(0.2)
            if let d = io.added(), confirmed(d, text: text) { return .sent }
        }
        return .unsure("按了 Enter，但對話裡沒看到這句")
    }
}
