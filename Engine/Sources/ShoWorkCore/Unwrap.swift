import Foundation

/// 擋單比對：把包裝裡面真正會跑的指令也切出來（防冒充方案 A，11-25）。
/// 只會「多切出」幾段給規則比，原本的段不變 ⇒ 原本會擋的照擋。看不出要跑什麼的回一段 opaque，由內建規則擋下等放行。
/// 這是擋順手繞過與意外；同帳號的程式存心寫檔再執行、改 hook，這裡擋不住。
public enum Unwrap {
    public static let opaque = "‹解不開的包裝›"
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    /// 後面接另一條指令的；值＝要跳過參數值的選項
    static let carriers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C"], "env": ["-u", "-S", "-C", "-P"], "command": [], "builtin": [], "nohup": [], "time": ["-o", "-f"], "exec": ["-a"], "nice": ["-n"], "ionice": ["-c", "-n"],
        "caffeinate": ["-t", "-w"], "timeout": ["-s", "-k"], "gtimeout": ["-s", "-k"], "stdbuf": ["-i", "-o", "-e"], "setsid": [], "arch": [], "xcrun": ["--sdk", "-sdk"], "doas": ["-u"],
        "xargs": ["-I", "-J", "-L", "-n", "-P", "-s", "-R", "-E", "-a", "-d"],
    ]

    /// 一段指令 → 裡面藏的指令（比對用的樣子）
    public static func inner(_ seg: String, depth: Int = 0) -> [String] {
        guard depth < 5 else { return [opaque] }
        var out = substitutions(seg).flatMap { all($0, depth: depth + 1) }       // "$( … )"、"` … `"
        let tok = tokens(seg)
        guard !tok.isEmpty else { return out }
        out += run(tok, depth: depth, changed: !seg.hasPrefix(tok[0]) || tok[0].contains("/"))
        return out
    }
    static func all(_ script: String, depth: Int) -> [String] {
        CaptainLink.rawSegments(script).flatMap { s -> [String] in [CaptainLink.blankQuotes(s)] + inner(s, depth: depth) }
    }

    static func run(_ t0: [String], depth: Int, changed c0: Bool) -> [String] {
        var t = t0, changed = c0, piped = false, hops = 0
        while let f = t.first, hops < 8 {
            hops += 1
            if f.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil { t.removeFirst(); changed = true; continue }
            let n = base(f)
            guard let skip = carriers[n] else { break }
            piped = piped || n == "xargs"
            t.removeFirst(); changed = true
            while let x = t.first, x.hasPrefix("-") {
                t.removeFirst()
                if x == "--" { break }
                if skip.contains(x), !t.isEmpty { let v = t.removeFirst(); if n == "env", x == "-S" { return all(v, depth: depth + 1) } }
            }
            if n == "timeout" || n == "gtimeout", !t.isEmpty { t.removeFirst() }
            if n == "command", t0.contains("-v") || t0.contains("-V") { return [] }      // 只是查在哪
        }
        guard let f = t.first else { return [] }
        let n = base(f), args = Array(t.dropFirst())
        if shells.contains(n) {
            var i = 0
            while i < args.count, args[i].hasPrefix("-") || args[i].hasPrefix("+") {
                if args[i].range(of: "^-[a-zA-Z]*c[a-zA-Z]*$", options: .regularExpression) != nil {
                    guard let s = args.dropFirst(i + 1).first(where: { !$0.hasPrefix("-") }) else { return [opaque] }
                    return script(s, depth)
                }
                i += args[i] == "-o" || args[i] == "+o" ? 2 : 1
            }
            return []
        }
        if n == "eval" { return args.isEmpty ? [] : script(args.joined(separator: " "), depth) }
        if n == "find" { return find(args, depth) }
        if n.range(of: #"^(python|python3(\.\d+)?|node|perl|ruby)$"#, options: .regularExpression) != nil,
           let k = args.firstIndex(where: { ["-c", "-e", "-E", "--eval", "-Ic", "-ne", "-pe"].contains($0) }), k + 1 < args.count {
            return deletes(args[k + 1]) ? ["rm " + n + "‹程式刪檔›"] : []
        }
        guard changed else { return [] }
        // 引號拆字、反斜線、完整路徑、前綴都還原成「名字 參數…」
        let a = args.map { $0.isEmpty ? "Q" : $0.replacingOccurrences(of: #"\s"#, with: "_", options: .regularExpression) }
        return [([n] + a + (piped && n == "rm" ? ["‹管線給的檔名›"] : [])).joined(separator: " ")]
    }
    /// 要跑的字串：整串是變數就看不出來
    static func script(_ s: String, _ depth: Int) -> [String] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^["']?\$(\{?[A-Za-z_@*#0-9]+[^}\s]*\}?)["']?$"#, options: .regularExpression) != nil { return [opaque] }
        return all(t, depth: depth + 1)
    }
    static func find(_ a: [String], _ depth: Int) -> [String] {
        let roots = a.prefix { !$0.hasPrefix("-") && $0 != "(" && $0 != "!" }.joined(separator: " ")
        var out: [String] = [], i = 0
        while i < a.count {
            if a[i] == "-delete" { out.append("rm " + (roots.isEmpty ? "." : roots)) }
            if ["-exec", "-execdir", "-ok", "-okdir"].contains(a[i]) {
                let body = a[(i + 1)...].prefix { $0 != ";" && $0 != "+" }.map { $0 == "{}" ? (roots.isEmpty ? "." : roots + "/x") : $0 }
                out += run(Array(body), depth: depth + 1, changed: true)
                i += body.count
            }
            i += 1
        }
        return out
    }
    /// 一行程式裡的刪檔寫法（常見的；暫存目錄的 cleanup 不算）
    static func deletes(_ code: String) -> Bool {
        code.range(of: #"\bos\.(remove|unlink|rmdir|removedirs)\b|\bshutil\.rmtree\b|\.(unlink|rmdir)\s*\(|\b(rmSync|unlinkSync|rmdirSync)\b|\bfs(\.promises)?\.(rm|unlink|rmdir)\b|\bunlink\s*[\s(]|\brmtree\b|\bFileUtils\.rm|\bFile\.delete\b"#, options: .regularExpression) != nil
    }
    static func base(_ s: String) -> String { s.split(separator: "/").last.map(String.init) ?? s }

    /// 雙引號裡的 $( … ) 與 ` … `（引號外的原本就會切開）；單引號內不展開
    static func substitutions(_ s: String) -> [String] {
        let c = Array(s); var out: [String] = [], i = 0, single = false, dbl = false
        while i < c.count {
            if c[i] == "\\", !single { i += 2; continue }
            if c[i] == "'", !dbl { single.toggle() } else if c[i] == "\"", !single { dbl.toggle() }
            else if dbl, c[i] == "$", i + 2 < c.count, c[i + 1] == "(", c[i + 2] != "(" {
                var d = 1, j = i + 2; while j < c.count, d > 0 { if c[j] == "(" { d += 1 } else if c[j] == ")" { d -= 1 }; j += 1 }
                out.append(String(c[(i + 2)..<max(i + 2, d == 0 ? j - 1 : j)])); i = j; continue
            } else if dbl, c[i] == "`", let e = c[(i + 1)...].firstIndex(of: "`") { out.append(String(c[(i + 1)..<e])); i = e + 1; continue }
            i += 1
        }
        return out
    }
    /// 照 shell 的規則拆字（引號、反斜線拿掉）；重導向不管
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", has = false, q: Character?, esc = false
        for ch in s {
            if esc { if ch != "\n" { cur.append(ch); has = true }; esc = false; continue }
            if ch == "\\", q != "'" { esc = true; continue }
            if let k = q { if ch == k { q = nil } else { cur.append(ch) }; continue }
            if ch == "'" || ch == "\"" { q = ch; has = true; continue }
            if ch.isWhitespace { if has { out.append(cur); cur = ""; has = false }; continue }
            cur.append(ch); has = true
        }
        if has { out.append(cur) }
        return out
    }
}
