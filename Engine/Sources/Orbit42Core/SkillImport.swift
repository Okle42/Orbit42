import Foundation

// 11-28 OpenJarvis 升級 B 組④：匯入現成 skill。
// 流程：搜尋（GitHub 公開 repo）→ 預覽（下載到暫存區 board/skills/staging/<名字>，印出內容＋危險掃描）→ Keng 核可 → 安裝到 ~/.claude/skills/<名字>。
// 只用 gh 讀公開資料；不執行 skill 裡的任何東西。掃到「危險」的不給裝（要另外加 --accept-risk，而且 Keng 要看過）。
public enum SkillImport {
    public typealias GH = (_ args: [String]) -> (code: Int32, out: String)

    public static var dir: URL { Paths.supportDir.appendingPathComponent("board/skills", isDirectory: true) }
    public static var staging: URL { dir.appendingPathComponent("staging", isDirectory: true) }
    public static var skillsDir: URL { TestEnv.home.appendingPathComponent(".claude/skills", isDirectory: true) }

    // MARK: 搜尋

    public struct Repo: Equatable, Sendable { public var name: String; public var stars: Int; public var desc: String }

    public static func search(_ q: String, gh: GH) -> [Repo] {
        let query = (q + " skill in:name,description,readme").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let r = gh(["api", "search/repositories?q=\(query)&sort=stars&per_page=10"])
        guard r.code == 0, let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { i in
            (i["full_name"] as? String).map { Repo(name: $0, stars: (i["stargazers_count"] as? Int) ?? 0, desc: (i["description"] as? String) ?? "") }
        }
    }

    /// repo 裡所有 SKILL.md 的資料夾（樹狀清單一次拿）
    public static func skills(in repo: String, gh: GH) -> [String] {
        let r = gh(["api", "repos/\(repo)/git/trees/HEAD?recursive=1"])
        guard r.code == 0, let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let tree = o["tree"] as? [[String: Any]] else { return [] }
        return tree.compactMap { $0["path"] as? String }.filter { $0 == "SKILL.md" || $0.hasSuffix("/SKILL.md") }
            .map { ($0 as NSString).deletingLastPathComponent }.sorted()
    }

    // MARK: 下載到暫存區

    public struct Staged: Codable, Equatable, Sendable {
        public var name: String          // 裝到 ~/.claude/skills/<name>
        public var repo: String
        public var path: String          // repo 裡的資料夾（"" = 根目錄）
        public var sha: String           // 下載當下的 commit
        public var files: [String]       // 相對路徑
        public var at: Date
    }

    static let maxFiles = 60, maxBytes = 2_000_000

    /// 從 repo 抓一個 skill 資料夾（含子資料夾）到暫存區。名字只收英數、-、_
    public static func fetch(repo: String, path: String, gh: GH, now: Date = Date(), into root: URL = staging) -> Result<Staged, CardError> {
        guard repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return .failure(CardError("repo 格式要是 owner/name")) }
        let shaR = gh(["api", "repos/\(repo)/commits/HEAD", "--jq", ".sha"])
        let sha = shaR.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shaR.code == 0, sha.count >= 7 else { return .failure(CardError("找不到 \(repo)（不是公開 repo 或網路不通）")) }
        let tr = gh(["api", "repos/\(repo)/git/trees/\(sha)?recursive=1"])
        guard tr.code == 0, let o = try? JSONSerialization.jsonObject(with: Data(tr.out.utf8)) as? [String: Any],
              let tree = o["tree"] as? [[String: Any]] else { return .failure(CardError("讀不到 \(repo) 的檔案清單")) }
        let prefix = path.isEmpty ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        let blobs = tree.filter { ($0["type"] as? String) == "blob" }.compactMap { b -> (String, Int)? in
            guard let p = b["path"] as? String, p.hasPrefix(prefix) else { return nil }
            return (String(p.dropFirst(prefix.count)), (b["size"] as? Int) ?? 0)
        }
        guard blobs.contains(where: { $0.0 == "SKILL.md" }) else { return .failure(CardError("\(repo)/\(path) 裡沒有 SKILL.md")) }
        guard blobs.count <= maxFiles else { return .failure(CardError("檔案太多（\(blobs.count) 個，上限 \(maxFiles)）")) }
        guard blobs.reduce(0, { $0 + $1.1 }) <= maxBytes else { return .failure(CardError("檔案太大（上限 2MB）")) }
        let base = path.isEmpty ? String(repo.split(separator: "/")[1]) : (path as NSString).lastPathComponent
        let name = base.lowercased().replacingOccurrences(of: #"[^a-z0-9_-]"#, with: "-", options: .regularExpression)
        let dest = root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }       // 只清自己的暫存區
        for (rel, _) in blobs {
            guard !rel.contains(".."), !rel.hasPrefix("/") else { return .failure(CardError("檔名不安全：\(rel)")) }
            let r = gh(["api", "repos/\(repo)/contents/\(prefix + rel)?ref=\(sha)", "-H", "Accept: application/vnd.github.raw"])
            guard r.code == 0 else { return .failure(CardError("下載失敗：\(rel)")) }
            let u = dest.appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try Data(r.out.utf8).write(to: u) } catch { return .failure(CardError("寫不進暫存區：\(rel)")) }
        }
        let s = Staged(name: name, repo: repo, path: path, sha: sha, files: blobs.map(\.0).sorted(), at: now)
        if let d = try? BoardJSON.encoder.encode(s) { try? d.write(to: root.appendingPathComponent(name + ".json")) }
        return .success(s)
    }

    public static func staged(_ name: String, root: URL = staging) -> Staged? {
        (try? Data(contentsOf: root.appendingPathComponent(name + ".json"))).flatMap { try? BoardJSON.decoder.decode(Staged.self, from: $0) }
    }

    // MARK: 危險掃描

    public enum Level: String, Codable, Sendable { case danger = "危險", caution = "注意" }
    public struct Finding: Equatable, Sendable { public var level: Level; public var file: String; public var line: Int; public var what: String; public var text: String }

    static let rules: [(Level, String, String)] = [
        (.danger, "刪除整個資料夾", #"\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+[~/$]"#),
        (.danger, "下載後直接執行", #"(curl|wget)[^|\n]*\|\s*(ba|z)?sh\b"#),
        (.danger, "解碼後執行", #"base64\s+(-d|--decode)[^|\n]*\|\s*(ba|z)?sh"#),
        (.danger, "讀 SSH 金鑰／雲端憑證", #"(~|\$HOME)/\.(ssh|aws|gnupg|config/gcloud)|id_rsa|id_ed25519"#),
        (.danger, "讀鑰匙圈密碼", #"security\s+find-(generic|internet)-password"#),
        (.danger, "把資料往外送", #"curl[^\n]*(-d|--data|-F|--form|-T|--upload-file)[^\n]*(\$\(|`|@~|@/|env|\.env|token|secret)"#),
        (.danger, "反向連線", #"\b(nc|ncat|netcat)\b[^\n]*-e\b|/dev/tcp/"#),
        (.danger, "要 AI 忽略原本規則", #"(?i)ignore (all )?(previous|prior|above) instructions|忽略(之前|先前|上面)的(指示|規則)"#),
        (.danger, "關掉權限確認", #"--dangerously-skip-permissions|bypassPermissions"#),
        (.caution, "sudo", #"\bsudo\b"#),
        (.caution, "開機自動執行／排程", #"\b(launchctl|crontab)\b|LaunchAgents"#),
        (.caution, "改權限 777", #"chmod\s+(-R\s+)?777"#),
        (.caution, "動態執行", #"\beval\s*[\(\"'$]|exec\(|os\.system\(|subprocess\.(run|Popen|call)\("#),
        (.caution, "AppleScript 控制其他 App", #"\bosascript\b"#),
        (.caution, "改 Claude Code 設定或 hook", #"\.claude/settings(\.local)?\.json|\"hooks\"\s*:"#),
        (.caution, "安裝套件", #"\b(pip3?|npm|brew|gem|cargo)\s+install\b"#),
        (.caution, "連到網址", #"https?://(?!github\.com/[^\s]*\.md)[^\s)\"'>]+"#),
    ]

    public static func scan(files: [(String, Data)]) -> [Finding] {
        let res = rules.compactMap { l, w, p in (try? NSRegularExpression(pattern: p)).map { (l, w, $0) } }
        var out: [Finding] = []
        for (f, d) in files {
            guard let s = String(data: d, encoding: .utf8) else {
                out.append(Finding(level: .caution, file: f, line: 0, what: "不是文字檔（看不到內容）", text: "")); continue
            }
            if d.prefix(4) == Data([0xCF, 0xFA, 0xED, 0xFE]) || d.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]) {
                out.append(Finding(level: .danger, file: f, line: 0, what: "附了可執行檔", text: "")); continue
            }
            for (n, raw) in s.components(separatedBy: "\n").enumerated() {
                let ns = raw as NSString
                for (l, w, re) in res where re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) != nil {
                    out.append(Finding(level: l, file: f, line: n + 1, what: w, text: String(raw.trimmingCharacters(in: .whitespaces).prefix(160))))
                }
                if !OutboundScan.secrets(raw).isEmpty { out.append(Finding(level: .danger, file: f, line: n + 1, what: "內含金鑰", text: "（不顯示）")) }
            }
        }
        return out
    }

    public static func scan(dir: URL, files: [String]) -> [Finding] {
        scan(files: files.compactMap { f in (try? Data(contentsOf: dir.appendingPathComponent(f))).map { (f, $0) } })
    }

    // MARK: 安裝

    public static func install(_ s: Staged, root: URL = staging, skills: URL = skillsDir, acceptRisk: Bool, replace: Bool, now: Date = Date()) -> Result<URL, CardError> {
        let src = root.appendingPathComponent(s.name, isDirectory: true)
        let found = scan(dir: src, files: s.files)
        if found.contains(where: { $0.level == .danger }), !acceptRisk {
            return .failure(CardError("掃到 \(found.filter { $0.level == .danger }.count) 處危險內容，不裝。Keng 看過仍要裝才加 --accept-risk"))
        }
        let fm = FileManager.default
        let dest = skills.appendingPathComponent(s.name, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            guard replace else { return .failure(CardError("~/.claude/skills/\(s.name) 已經有了；要換成新的加 --replace（舊的會備份）")) }
            let bak = dir.appendingPathComponent("backup/\(s.name)-\(Int(now.timeIntervalSince1970))")
            try? fm.createDirectory(at: bak.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.moveItem(at: dest, to: bak) } catch { return .failure(CardError("舊的備份不了：\(error.localizedDescription)")) }
        }
        do {
            try fm.createDirectory(at: skills, withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dest)
        } catch { return .failure(CardError("複製失敗：\(error.localizedDescription)")) }
        // 來源紀錄：之後要追更新、要撤掉都查得到
        let rec: [String: Any] = ["at": ISO8601DateFormatter().string(from: now), "name": s.name, "repo": s.repo, "path": s.path, "sha": s.sha,
                                  "files": s.files.count, "danger": found.filter { $0.level == .danger }.count, "caution": found.filter { $0.level == .caution }.count]
        if var d = try? JSONSerialization.data(withJSONObject: rec) {
            d.append(0x0A)
            let log = dir.appendingPathComponent("imported.jsonl")
            if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: log) }
        }
        return .success(dest)
    }

    /// 真的 gh（只用 GET 讀公開資料）
    public static func realGH(_ args: [String]) -> (code: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["gh"] + args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (127, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
}
