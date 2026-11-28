import Foundation
import Orbit42Core

// 11-28 B 組④ 匯入現成 skill（SkillImport.swift）
//   orbit skill search "<關鍵字>"              GitHub 公開 repo 搜尋
//   orbit skill list <owner/repo>              repo 裡有哪些 skill（SKILL.md 所在資料夾）
//   orbit skill preview <owner/repo> [資料夾]   下載到暫存區，印出 SKILL.md 全文、檔案清單、危險掃描
//   orbit skill install <名字> --yes [--accept-risk] [--replace]   Keng 在卡片核可後才跑；掃到危險不給裝
enum SkillCLI {
    static func run(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        let sub = a.isEmpty ? "help" : a.removeFirst()
        let pos = a.filter { !$0.hasPrefix("--") }
        func err(_ s: String) -> Int32 { FileHandle.standardError.write(Data((s + "\n").utf8)); return 1 }
        switch sub {
        case "search":
            guard let q = pos.first else { return err("用法：orbit skill search \"<關鍵字>\"") }
            let rs = SkillImport.search(q, gh: SkillImport.realGH)
            if rs.isEmpty { print("找不到（或 gh 沒登入／網路不通）。"); return 0 }
            for r in rs { print("★\(r.stars)  \(r.name)  \(r.desc.prefix(80))") }
            print("下一步：orbit skill list <owner/repo>")
            return 0
        case "list":
            guard let repo = pos.first else { return err("用法：orbit skill list <owner/repo>") }
            let ss = SkillImport.skills(in: repo, gh: SkillImport.realGH)
            if ss.isEmpty { print("\(repo) 裡沒有 SKILL.md。"); return 0 }
            for s in ss { print(s.isEmpty ? "（根目錄）" : s) }
            print("下一步：orbit skill preview \(repo) <資料夾>")
            return 0
        case "preview":
            guard let repo = pos.first else { return err("用法：orbit skill preview <owner/repo> [資料夾]") }
            switch SkillImport.fetch(repo: repo, path: pos.count > 1 ? pos[1] : "", gh: SkillImport.realGH) {
            case .failure(let e): return err("orbit skill preview：\(e.message)")
            case .success(let s):
                let d = SkillImport.staging.appendingPathComponent(s.name)
                print("【\(s.name)】來源 \(s.repo)/\(s.path)＠\(s.sha.prefix(8))，\(s.files.count) 個檔：")
                for f in s.files { print("  " + f) }
                print("\n----- SKILL.md 全文 -----")
                print((try? String(contentsOf: d.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "（讀不到）")
                print("----- 危險掃描 -----")
                let fs = SkillImport.scan(dir: d, files: s.files)
                if fs.isEmpty { print("沒掃到危險或要注意的內容。") }
                for f in fs.sorted(by: { $0.level == .danger && $1.level != .danger }) { print("［\(f.level.rawValue)］\(f.file):\(f.line) \(f.what)  \(f.text)") }
                let danger = fs.filter { $0.level == .danger }.count
                print("\n暫存在 \(d.path)（還沒裝）。" + (danger > 0 ? "有 \(danger) 處危險，預設不給裝。" : "Keng 核可後：orbit skill install \(s.name) --yes"))
                return 0
            }
        case "install":
            guard let name = pos.first, let s = SkillImport.staged(name) else { return err("找不到暫存的 skill；先跑 orbit skill preview") }
            guard a.contains("--yes") else { return err("要 Keng 在卡片上核可後才裝；核可了再加 --yes") }
            switch SkillImport.install(s, acceptRisk: a.contains("--accept-risk"), replace: a.contains("--replace")) {
            case .failure(let e): return err("orbit skill install：\(e.message)")
            case .success(let u): print("已裝到 \(u.path)（來源 \(s.repo)＠\(s.sha.prefix(8))，紀錄在 board/skills/imported.jsonl）。新開的 Claude Code session 才會看到。"); return 0
            }
        default:
            return err("用法：orbit skill search \"<關鍵字>\"｜list <owner/repo>｜preview <owner/repo> [資料夾]｜install <名字> --yes")
        }
    }
}
