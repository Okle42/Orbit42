import Foundation

// 11-28 OpenJarvis 升級 B 組⑥：對外訊息自動遮個資。
// push 之前已經有 PushGuard 擋密鑰；這裡把同一套密鑰規則用在其他對外動作：gh 留言／開單、LINE 送出、寄信（gmail_send.py）。
//   ・掃到密鑰 ⇒ 擋（deny），要把密鑰拿掉再送
//   ・掃到個資（手機、市話、身分證、地址、keywords.txt 的客戶名）⇒ 先警告（deny 一次）並附上遮好的版本；
//     AI 判斷原文真的要送，10 分鐘內送「一模一樣」的指令就放行（警告不是擋，決定權在送的人）
// 只看指令本身與它指名的訊息檔（--body-file、$(cat 檔)），不連網、不上傳，紀錄只存本機。
public enum OutboundScan {
    public enum Channel: String, Codable, Sendable { case gh = "GitHub 留言", line = "LINE 送出", mail = "寄信" }

    public struct Finding: Equatable, Sendable {
        public var kind: String       // 手機／市話／身分證／地址／客戶名
        public var masked: String     // 遮過的樣子（不把原文再印一次）
    }

    public struct Hit: Equatable, Sendable {
        public var channel: Channel
        public var text: String
        public var secrets: [String]
        public var pii: [Finding]
        public var redacted: String
        public var blocked: Bool { !secrets.isEmpty }
        public var warned: Bool { secrets.isEmpty && !pii.isEmpty }
    }

    public typealias Reader = (_ path: String) -> String?

    // MARK: 找出指令要送出去的文字

    /// 這個指令要對外送出的文字（依通道）。看不懂的指令回空陣列＝不管
    public static func messages(_ cmd: String, cwd: String, read: Reader) -> [(Channel, String)] {
        var out: [(Channel, String)] = []
        var seg: [String] = []
        func file(_ p: String) -> String? {
            guard p != "-", !p.contains("$") else { return nil }
            let e = (p as NSString).expandingTildeInPath
            return read(e.hasPrefix("/") ? e : (cwd as NSString).appendingPathComponent(e))
        }
        /// 參數值：$(cat 檔) 讀檔，其他照原文
        func value(_ v: String) -> String {
            guard let re = try? NSRegularExpression(pattern: #"\$\(\s*cat\s+([^)\s]+)\s*\)"#) else { return v }
            let ns = v as NSString
            var s = v
            for m in re.matches(in: v, range: NSRange(location: 0, length: ns.length)).reversed() {
                let p = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                s = (s as NSString).replacingCharacters(in: m.range, with: file(p) ?? "")
            }
            return s
        }
        func handle(_ t: [String]) {
            guard let first = t.first else { return }
            let name = (first as NSString).lastPathComponent
            var args = Array(t.dropFirst())
            if ["python3", "python"].contains(name), let s = args.first { handleScript(s, Array(args.dropFirst())); return }
            if name == "gh" {
                let sub = (args.first ?? "") + " " + (args.count > 1 ? args[1] : "")
                let speaks: Set<String> = ["issue comment", "issue create", "pr create", "pr comment", "pr review", "release create", "issue edit", "pr edit"]
                if args.first == "api" { args = Array(args.dropFirst()) }
                else if speaks.contains(sub) { args = Array(args.dropFirst(2)) }
                else { return }
                var texts: [String] = []
                var i = 0
                while i < args.count {
                    let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
                    if ["-b", "--body", "-t", "--title", "-n", "--notes"].contains(a), let n = next { texts.append(value(n)); i += 2; continue }
                    if ["--body-file", "-F", "--notes-file"].contains(a), let n = next, !n.contains("=") { if let s = file(n) { texts.append(s) }; i += 2; continue }
                    if ["-f", "--raw-field", "--field"].contains(a), let n = next {         // gh api -f body=…
                        if let eq = n.firstIndex(of: "=") { let v = String(n[n.index(after: eq)...]); texts.append(v.hasPrefix("@") ? (file(String(v.dropFirst())) ?? "") : value(v)) }
                        i += 2; continue
                    }
                    if a.hasPrefix("--body=") || a.hasPrefix("--title=") { texts.append(value(String(a[a.index(after: a.firstIndex(of: "=")!)...]))) }
                    if a.hasPrefix("--body-file=") { if let s = file(String(a.dropFirst(12))) { texts.append(s) } }
                    i += 1
                }
                let j = texts.filter { !$0.isEmpty }.joined(separator: "\n")
                if !j.isEmpty { out.append((.gh, j)) }
                return
            }
            if name.hasSuffix(".py") { handleScript(first, args) }
        }
        func handleScript(_ script: String, _ args: [String]) {
            let s = (script as NSString).lastPathComponent
            if s.hasPrefix("line_send") || s.hasPrefix("line_broadcast") {
                // line_send.py <收件人> <訊息>：收件人本來就是要送的對象，不算洩漏，只看訊息
                var pos: [String] = [], texts: [String] = []
                var i = 0
                while i < args.count {
                    let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
                    if ["--text", "--msg", "-m", "--message"].contains(a), let n = next { texts.append(value(n)); i += 2; continue }
                    if ["--file", "--text-file"].contains(a), let n = next { if let x = file(n) { texts.append(x) }; i += 2; continue }
                    if !a.hasPrefix("-") { pos.append(a) }
                    i += 1
                }
                texts += (s.hasPrefix("line_send") ? Array(pos.dropFirst()) : pos).map(value)
                let j = texts.filter { !$0.isEmpty }.joined(separator: "\n")
                if !j.isEmpty { out.append((.line, j)) }
            } else if s.hasPrefix("gmail_send"), !args.contains("--dry-run") {      // 試跑不寄
                var texts: [String] = []
                var i = 0
                while i < args.count {
                    let a = args[i], next = i + 1 < args.count ? args[i + 1] : nil
                    if a == "--body-file", let n = next { if let x = file(n) { texts.append(x) }; i += 2; continue }
                    if a == "--subject", let n = next { texts.append(value(n)); i += 2; continue }
                    i += 1
                }
                let j = texts.filter { !$0.isEmpty }.joined(separator: "\n")
                if !j.isEmpty { out.append((.mail, j)) }
            }
        }
        for t in PushGuard.tokenize(cmd) {
            if [";", "&&", "||", "|", "&"].contains(t) { handle(seg); seg = [] } else { seg.append(t) }
        }
        handle(seg)
        return out
    }

    // MARK: 掃描

    public static func secrets(_ text: String) -> [String] {
        let ns = text as NSString
        return PushGuard.secretPatterns.compactMap { n, p in
            (try? NSRegularExpression(pattern: p)).flatMap { $0.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil ? n : nil }
        }
    }

    /// 個資規則（台灣）：(種類, 規則, 遮法)
    static let piiRules: [(String, String)] = [
        ("身分證", #"(?<![A-Za-z0-9])[A-Z][1289]\d{8}(?![0-9])"#),
        ("手機", #"(?<![0-9])(?:\+886[-\s]?|0)9\d{2}[-\s]?\d{3}[-\s]?\d{3}(?![0-9])"#),
        ("市話", #"(?<![0-9])(?:\(0[2-8]\d?\)\s?|0[2-8]\d?-)\d{3,4}-?\d{4}(?![0-9])"#),
        ("地址", #"(?:\p{Han}{1,3}[市縣])?\p{Han}{1,3}[區鄉鎮市]\p{Han}{1,6}(?:路|街|大道)(?:[一二三四五六七八九十\d]段)?(?:\d+巷)?(?:\d+弄)?\d+(?:之\d+)?號(?:\d+樓)?(?:之\d+)?"#),
    ]

    /// 身分證檢查碼（台灣）：字母換兩位數，加權和 ≡ 0 (mod 10)
    static func validID(_ s: String) -> Bool {
        let letters = "ABCDEFGHJKLMNPQRSTUVXYWZIO"
        let c = Array(s)
        guard c.count == 10, let li = letters.firstIndex(of: c[0]) else { return false }
        let n = letters.distance(from: letters.startIndex, to: li) + 10
        var sum = n / 10 + (n % 10) * 9
        let w = [8, 7, 6, 5, 4, 3, 2, 1, 1]
        for k in 1..<10 { guard let d = c[k].wholeNumberValue else { return false }; sum += d * w[k - 1] }
        return sum % 10 == 0
    }

    /// 找到的每一段：(範圍, 種類)
    static func spans(_ text: String, keywords: [String]) -> [(NSRange, String)] {
        let ns = text as NSString
        var out: [(NSRange, String)] = []
        for (kind, p) in piiRules {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if kind == "身分證", !validID(ns.substring(with: m.range)) { continue }
                out.append((m.range, kind))
            }
        }
        for w in keywords where !w.isEmpty {
            var r = ns.range(of: w, options: .caseInsensitive)
            while r.location != NSNotFound {
                out.append((r, "客戶名"))
                let start = r.location + r.length
                r = ns.range(of: w, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
            }
        }
        for (_, p) in PushGuard.secretPatterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { out.append((m.range, "密鑰")) }
        }
        // 重疊的留先出現、較長的
        out.sort { $0.0.location != $1.0.location ? $0.0.location < $1.0.location : $0.0.length > $1.0.length }
        var kept: [(NSRange, String)] = []
        for s in out where !kept.contains(where: { NSIntersectionRange($0.0, s.0).length > 0 }) { kept.append(s) }
        return kept
    }

    static func mask(_ s: String, kind: String) -> String {
        let c = Array(s)
        switch kind {
        case "手機", "市話":
            // 留前 4 個字元，其他數字換成 *
            var n = 0
            return String(c.map { ch in if ch.isNumber { n += 1; return n <= 4 ? ch : "*" }; return ch })
        case "身分證": return String(c.prefix(2)) + String(repeating: "*", count: max(0, c.count - 2))
        case "地址":
            // 留到「區／鄉／鎮」，後面遮掉
            if let i = c.firstIndex(where: { "區鄉鎮".contains($0) }) { return String(c[...i]) + "＊＊＊" }
            return String(c.prefix(3)) + "＊＊＊"
        case "客戶名": return "（客戶）"
        case "密鑰": return "［已移除的密鑰］"
        default: return String(repeating: "*", count: c.count)
        }
    }

    public static func pii(_ text: String, keywords: [String]) -> [Finding] {
        let ns = text as NSString
        return spans(text, keywords: keywords).filter { $0.1 != "密鑰" }.map { Finding(kind: $0.1, masked: mask(ns.substring(with: $0.0), kind: $0.1)) }
    }

    /// 遮好的版本（個資與密鑰都換掉）
    public static func redact(_ text: String, keywords: [String]) -> String {
        let ns = NSMutableString(string: text)
        for (r, k) in spans(text, keywords: keywords).reversed() { ns.replaceCharacters(in: r, with: mask(ns.substring(with: r), kind: k)) }
        return ns as String
    }

    public static func check(_ cmd: String, cwd: String, keywords: [String], read: Reader) -> [Hit] {
        messages(cmd, cwd: cwd, read: read).compactMap { ch, t in
            let s = secrets(t), p = pii(t, keywords: keywords)
            return s.isEmpty && p.isEmpty ? nil : Hit(channel: ch, text: t, secrets: s, pii: p, redacted: redact(t, keywords: keywords))
        }
    }

    // MARK: 警告後「同一個指令再送一次」放行

    public struct Ack: Codable, Sendable, Equatable { public var fp: String; public var until: Date }
    public static let ackFor: TimeInterval = 10 * 60
    public static var ackURL: URL { PushGuard.dir.appendingPathComponent("outbound-ack.json") }
    public static var logURL: URL { PushGuard.dir.appendingPathComponent("outbound.jsonl") }

    public static func fingerprint(_ cmd: String, session: String?) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in ((session ?? "") + "|" + cmd).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 這個指令剛被警告過（10 分鐘內）⇒ 這次放行並用掉；否則記下、回 false
    public static func acknowledged(_ fp: String, now: Date = Date(), url: URL = ackURL) -> Bool {
        var xs = ((try? Data(contentsOf: url)).flatMap { try? BoardJSON.decoder.decode([Ack].self, from: $0) } ?? []).filter { $0.until > now }
        let hit = xs.contains { $0.fp == fp }
        if hit { xs.removeAll { $0.fp == fp } } else { xs.append(Ack(fp: fp, until: now + ackFor)) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? BoardJSON.encoder.encode(xs) { try? d.write(to: url, options: .atomic) }
        return hit
    }

    /// PreToolUse 的回應。acked＝這次是警告後的重送（個資放行，密鑰照擋）。nil＝沒事
    public static func hookOutput(_ hits: [Hit], acked: Bool) -> String? {
        let blocked = hits.filter(\.blocked), warned = hits.filter(\.warned)
        let reason: String
        if !blocked.isEmpty {
            reason = "🛡️ 對外訊息被保全擋下：" + blocked.map { "\($0.channel.rawValue)裡有\($0.secrets.joined(separator: "、"))" }.joined(separator: "；")
                + "。\n密鑰不能送出去（不是網路壞了，不要重試同一個指令、也不要換寫法繞過）。把密鑰拿掉再送；遮好的版本：\n"
                + blocked.map { "-----\n" + String($0.redacted.prefix(1500)) }.joined(separator: "\n")
                + "\n用 orbit card --status blocked 回報被擋的原因。"
        } else if !warned.isEmpty, !acked {
            reason = "🛡️ 對外訊息含個資，先停一下：" + warned.map { "\($0.channel.rawValue)：" + $0.pii.map { "\($0.kind) \($0.masked)" }.joined(separator: "、") }.joined(separator: "；")
                + "。\n建議改送遮好的版本：\n" + warned.map { "-----\n" + String($0.redacted.prefix(1500)) }.joined(separator: "\n")
                + "\n如果原文本來就該給對方（例如回客戶他自己的電話），10 分鐘內再送一次一模一樣的指令就會放行；不確定就問使用者。"
        } else { return nil }
        let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self)
    }

    /// 本機紀錄（不存原文，只存遮過的樣子）
    public static func log(_ hits: [Hit], session: String?, released: Bool, now: Date = Date(), url: URL = logURL) {
        guard !hits.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for h in hits {
            let o: [String: Any] = ["at": ISO8601DateFormatter().string(from: now), "session": session ?? "", "channel": h.channel.rawValue,
                                    "verdict": h.blocked ? "block" : (released ? "warn-released" : "warn"),
                                    "secrets": h.secrets, "pii": h.pii.map { "\($0.kind) \($0.masked)" }]
            guard var d = try? JSONSerialization.data(withJSONObject: o) else { continue }
            d.append(0x0A)
            if let f = try? FileHandle(forWritingTo: url) { f.seekToEndOfFile(); f.write(d); try? f.close() } else { try? d.write(to: url) }
        }
    }
}
