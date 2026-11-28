import Foundation
import Orbit42Core

// 11-28 OpenJarvis 升級 A 組：
//   orbit search "<問題>" [--source mail,calendar,drive,imessage] [--limit N] [--json]   查本機個人資料索引，每筆附出處
//   orbit search import <mail|calendar|drive|imessage> <檔.jsonl|->                        把抓下來的資料寫進索引（一行一筆 JSON）
//   orbit search sync <imessage|mail|drive|all> [--days N]                                 從來源唯讀抓進索引
//   orbit search stats                                                                      各來源幾筆、最後更新
//   orbit morning [--no-ai] [--mp3 <檔>] [--json]                                          產今天的晨報稿（＋用球體選的聲音做 mp3）
//   orbit morning set <HH:MM|off|on>                                                        晨報時間（預設 08:30）
// 個人資料只讀、只存本機（~/Library/Application Support/Orbit42/personal/），不上傳任何地方；
// 晨報稿交給本機 claude -p（haiku）改口語時，只送條列的事實（行程標題、寄件人、信的主旨），不送信的內文。
enum PersonalCLI {
    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func search(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        do {
            if a.first == "stats" {
                let ix = try PersonalIndex()
                let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
                for (s, n, last) in try ix.stats() { print("\(s.zh)（\(s.rawValue)）：\(n) 筆" + (last.map { "，最後更新 \(f.string(from: $0))" } ?? "")) }
                print("索引：\(ix.url.path)")
                return 0
            }
            if a.first == "sync" {
                // orbit search sync <imessage|mail|drive|all> [--days N]：重的工作一次只跑一個（16GB），所以一個接一個
                let what = a.count > 1 ? a[1] : "all"
                let days = a.firstIndex(of: "--days").flatMap { a.indices.contains($0 + 1) ? Int(a[$0 + 1]) : nil }
                let ix = try PersonalIndex()
                var bad = false
                if what == "imessage" || what == "all" {
                    do { let d = try IMessageReader.read(days: days ?? 30); print("iMessage：寫進 \(try ix.upsert(d)) 筆（一個對話一天一筆）") }
                    catch { err("\(error)"); bad = true }
                }
                for k in ConnectorSync.Kind.allCases where what == k.rawValue || what == "all" {
                    let name = k == .mail ? "Gmail" : "Drive"
                    guard let out = BriefRunner.connector(k, days: days ?? (k == .mail ? 7 : 30)) else {
                        err("\(name)：claude 連接器沒回東西（先在終端機跑 /mcp 重新登入 claude.ai \(name)）"); bad = true; continue
                    }
                    let docs = ConnectorSync.parse(out, kind: k)
                    if docs.isEmpty { err("\(name)：一筆都沒抓到。claude 回：\(out.prefix(300))"); bad = true; continue }
                    print("\(name)：寫進 \(try ix.upsert(docs)) 筆")
                }
                return bad ? 1 : 0
            }
            if a.first == "import" {
                guard a.count >= 3, let src = PersonalDoc.Source(rawValue: a[1]) else { err("用法：orbit search import <mail|calendar|drive|imessage> <檔.jsonl|->"); return 1 }
                let data = a[2] == "-" ? FileHandle.standardInput.readDataToEndOfFile() : (FileManager.default.contents(atPath: a[2]) ?? Data())
                let (docs, bad) = PersonalImport.parse(data)
                let wrong = docs.filter { $0.source != src }.count
                let n = try PersonalIndex().upsert(docs.filter { $0.source == src })
                print("寫進 \(n) 筆\(src.zh)" + (bad > 0 ? "，\(bad) 行看不懂略過" : "") + (wrong > 0 ? "，\(wrong) 筆來源不是 \(src.rawValue) 略過" : ""))
                return 0
            }
            var sources: Set<PersonalDoc.Source>?, limit = 8, json = false, words: [String] = []
            while !a.isEmpty {
                let k = a.removeFirst()
                switch k {
                case "--source": sources = Set((a.isEmpty ? "" : a.removeFirst()).split(separator: ",").compactMap { PersonalDoc.Source(rawValue: String($0)) })
                case "--limit": limit = Int(a.isEmpty ? "" : a.removeFirst()) ?? 8
                case "--json": json = true
                default: words.append(k)
                }
            }
            let q = words.joined(separator: " ")
            guard !q.isEmpty else { err("用法：orbit search \"<問題>\" [--source mail,calendar,drive,imessage] [--limit N] [--json]"); return 1 }
            let ix = try PersonalIndex()
            let hits = try ix.search(q, sources: sources, limit: limit)
            if json {
                let iso = ISO8601DateFormatter()
                let o: [[String: Any]] = hits.map { h in
                    ["source": h.doc.source.rawValue, "title": h.doc.title, "who": h.doc.who ?? "", "at": iso.string(from: h.doc.at),
                     "link": h.doc.link ?? "", "ref": h.doc.ref, "snippet": h.snippet, "cite": h.cite]
                }
                let d = try JSONSerialization.data(withJSONObject: ["query": q, "keywords": PersonalIndex.keywords(q), "hits": o], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: d, as: UTF8.self))
                return 0
            }
            if hits.isEmpty {
                let empty = try ix.stats().allSatisfy { $0.1 == 0 }
                print(empty ? "索引還是空的（還沒接 Gmail／行事曆／Drive）。先跑 orbit search import …" : "找不到「\(q)」（關鍵詞：\(PersonalIndex.keywords(q).joined(separator: "、"))）")
                return empty ? 2 : 1
            }
            for (i, h) in hits.enumerated() {
                print("\(i + 1). 【\(h.cite)】")
                if !h.snippet.isEmpty { print("   \(h.snippet)") }
                if let l = h.doc.link, !l.isEmpty { print("   \(l)") }
            }
            return 0
        } catch { err("\(error)"); return 1 }
    }

    // MARK: 晨報

    static func morning(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        if a.first == "set" {
            var s = MorningBrief.settings()
            let v = a.count > 1 ? a[1] : ""
            if v == "off" { s.enabled = false } else if v == "on" { s.enabled = true }
            else {
                let p = v.split(separator: ":").compactMap { Int($0) }
                guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { err("用法：orbit morning set <HH:MM|off|on>"); return 1 }
                s.hour = p[0]; s.minute = p[1]; s.enabled = true
            }
            do { try MorningBrief.save(s) } catch { err("存不進去：\(error)"); return 1 }
            print(s.enabled ? String(format: "晨報時間：每天 %02d:%02d（人在 Mac 前才念）", s.hour, s.minute) : "晨報：關")
            return 0
        }
        var ai = true, mp3: String?, json = false
        while !a.isEmpty {
            let k = a.removeFirst()
            switch k {
            case "--no-ai": ai = false
            case "--mp3": mp3 = a.isEmpty ? nil : a.removeFirst()
            case "--json": json = true
            default: err("看不懂 \(k)。用法：orbit morning [--no-ai] [--mp3 <檔>] [--json]"); return 1
            }
        }
        let r = BriefRunner.compose(ai: ai)
        var audio: String?
        if let mp3 {
            switch BriefRunner.render(r.text, to: URL(fileURLWithPath: mp3)) {
            case .success(let u): audio = u.path
            case .failure(let e): err("聲音檔做不出來：\(e.message)")
            }
        }
        if json {
            let o: [String: Any] = ["text": r.text, "draft": r.draft, "ai": r.byAI, "sentences": MorningBrief.sentences(r.text),
                                    "facts": r.factSheet, "audio": audio ?? NSNull(), "voice": BriefRunner.voice]
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { print(String(decoding: d, as: UTF8.self)) }
        } else {
            print(r.text)
            print("\n（\(r.byAI ? "AI 口語稿" : "規則草稿")，\(r.text.count) 字" + (audio.map { "；聲音檔：\($0)" } ?? "") + "）")
        }
        return 0
    }
}

/// 晨報：收集 → 稿子 → 聲音檔（CLI 和 App 共用）
enum BriefRunner {
    struct Result { var text: String; var draft: String; var byAI: Bool; var factSheet: String }

    static func compose(ai: Bool, now: Date = Date()) -> Result {
        let ix = try? PersonalIndex()
        let names = NicknameStore.all().mapValues(\.name)
        let f = MorningBrief.gather(index: ix, asks: AskQueue.all(), names: names, now: now)
        let draft = MorningBrief.draft(f), sheet = MorningBrief.factSheet(f)
        if ai, let bin = claudeBin, case let r = sh(bin, MorningBrief.claudeArgs, stdin: sheet, timeout: 45), r.code == 0, case let out = r.out, let t = MorningBrief.tidy(out) {
            return Result(text: t, draft: draft, byAI: true, factSheet: sheet)
        }
        return Result(text: draft, draft: draft, byAI: false, factSheet: sheet)
    }

    static var claudeBin: String? {
        [NSHomeDirectory() + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Gmail／Drive 連接器（claude.ai 已連好的）：只放行唯讀工具，其餘工具一律不給；不帶 hook、不存對話
    static func connector(_ k: ConnectorSync.Kind, days: Int) -> String? {
        guard let bin = claudeBin else { return nil }
        let r = sh(bin, ConnectorSync.claudeArgs(k),
                   stdin: ConnectorSync.prompt(k, days: days), timeout: 300)
        return r.code == 0 && !r.out.isEmpty ? r.out : nil
    }

    /// 球體目前選的聲音（App 存在 ai.okle42.orbit42.engine 的 sphere.voiceId）
    static var voice: String { UserDefaults(suiteName: AppPrefs.suite)?.string(forKey: "sphere.voiceId") ?? "edge:zh-TW-HsiaoChenNeural" }

    static var edgeBin: String? {
        [ProcessInfo.processInfo.environment["ORBIT_EDGE_TTS"], NSHomeDirectory() + "/github-repos/lipsync-lab/.venv/bin/edge-tts", "/opt/homebrew/bin/edge-tts"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct RenderError: Error { let message: String }

    /// 微軟神經語音 → mp3；Mac 內建語音 → say 出 aiff 再轉 m4a（副檔名自動改）
    static func render(_ text: String, to out: URL) -> Swift.Result<URL, RenderError> {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let v = voice
        if v.hasPrefix("edge:"), let bin = edgeBin {
            let r = sh(bin, ["-v", String(v.dropFirst(5)), "--text=\(text)", "--write-media=\(out.path)"], timeout: 60)
            return r.code == 0 ? .success(out) : .failure(RenderError(message: "edge-tts 失敗（要網路）：\(r.err.prefix(200))"))
        }
        let aiff = out.deletingPathExtension().appendingPathExtension("aiff"), m4a = out.deletingPathExtension().appendingPathExtension("m4a")
        var sayArgs = ["-o", aiff.path, text]
        if v.hasPrefix("apple:"), let name = v.split(separator: ".").last.map(String.init), !name.isEmpty { sayArgs = ["-v", name.replacingOccurrences(of: "-premium", with: "").replacingOccurrences(of: "-compact", with: "")] + sayArgs }
        var r = sh("/usr/bin/say", sayArgs, timeout: 60)
        if r.code != 0 { r = sh("/usr/bin/say", ["-o", aiff.path, text], timeout: 60) }
        guard r.code == 0 else { return .failure(RenderError(message: "say 失敗：\(r.err.prefix(200))")) }
        let c = sh("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, m4a.path], timeout: 60)
        return c.code == 0 ? .success(m4a) : .success(aiff)
    }

    static func sh(_ bin: String, _ args: [String], stdin: String? = nil, timeout: TimeInterval) -> (code: Int32, out: String, err: String) {
        let p = Process(), o = Pipe(), e = Pipe(), i = Pipe()
        p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        p.standardOutput = o; p.standardError = e; p.standardInput = stdin == nil ? FileHandle.nullDevice : i
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)); try? i.fileHandleForWriting.close() }
        var outD = Data(), errD = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { outD = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { errD = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); _ = g.wait(timeout: .now() + 2); return (-2, "", "逾時") }
        _ = g.wait(timeout: .now() + 5)
        return (p.terminationStatus, String(decoding: outD, as: UTF8.self), String(decoding: errD, as: UTF8.self))
    }
}
