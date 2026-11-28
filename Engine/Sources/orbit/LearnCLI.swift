import Foundation
import Orbit42Core

// 11-28 B 組③ 從過去紀錄自動變聰明（Lessons.swift）
//   orbit learn scan [--days 2] [--repo <git 資料夾>]   收交流板／派工回報／Keng 原話／指正紀錄，叫本機 haiku 整理成建議（只存待核可）
//   orbit learn list [--all]                            看建議（預設只列待核可）
//   orbit learn approve <編號…> | reject <編號…>        Keng 在卡片上核可後才跑；派工提醒核可後自動附進之後的派工單
//   orbit learn reminders                               目前會附進派工單的提醒
enum LearnCLI {
    static func commits(_ repo: String, since: Date) -> [(Date, String)] {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repo, "log", "--since=\(Int(since.timeIntervalSince1970))", "--format=%ct\t%s", "-n", "300"]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { l in
            let x = l.split(separator: "\t", maxSplits: 1)
            guard x.count == 2, let t = Double(x[0]) else { return nil }
            return (Date(timeIntervalSince1970: t), String(x[1]))
        }
    }

    static func run(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        let sub = a.isEmpty ? "list" : a.removeFirst()
        func value(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        func err(_ s: String) -> Int32 { FileHandle.standardError.write(Data((s + "\n").utf8)); return 1 }
        switch sub {
        case "scan":
            let days = max(1, Int(value("--days") ?? "") ?? 2)
            let since = Date().addingTimeInterval(-Double(days) * 86400)
            let repo = value("--repo") ?? FileManager.default.currentDirectoryPath
            let src = Lessons.sources(since: since, posts: B1Board.all(), tasks: CaptainStore.tasks(),
                                      memories: Lessons.feedbackMemories(since: since), commits: commits(repo, since: since))
            print("收到 \(src.count) 筆紀錄（最近 \(days) 天），交給本機 haiku 整理⋯")
            switch Lessons.scan(src, run: Lessons.haiku) {
            case .failure(let e): return err("orbit learn scan：\(e.message)")
            case .success(let new):
                print("新建議 \(new.count) 條（都是待核可，Keng 核可前不會生效）：")
                for s in new { print(Lessons.line(s)) }
                return 0
            }
        case "list":
            let xs = Lessons.all().filter { a.contains("--all") || $0.state == .pending }
            if xs.isEmpty { print(a.contains("--all") ? "還沒有建議。先跑 orbit learn scan" : "沒有待核可的建議。") }
            for s in xs { print(Lessons.line(s)) }
            return 0
        case "approve", "reject":
            guard !a.isEmpty else { return err("用法：orbit learn \(sub) <編號…>") }
            var bad = false
            for id in a {
                if let s = Lessons.decide(id, approve: sub == "approve") {
                    print("\(s.id) → \(s.state.rawValue)：\(s.title)" + (s.state == .approved && s.kind != .reminder ? "（要改 \(s.target ?? "對應的檔")，這裡不自動改，請派人改）" : ""))
                } else { _ = err("找不到建議 \(id)"); bad = true }
            }
            return bad ? 1 : 0
        case "reminders":
            let r = Lessons.reminders()
            print(r.isEmpty ? "目前沒有會附進派工單的提醒。" : r.map { "・" + $0 }.joined(separator: "\n"))
            return 0
        default:
            return err("用法：orbit learn scan [--days 2]｜list [--all]｜approve <編號…>｜reject <編號…>｜reminders")
        }
    }
}
