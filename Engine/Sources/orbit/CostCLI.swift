import Foundation
import Orbit42Core

// 11-28 B 組⑤ 花費紀錄（CostLog.swift）
//   orbit cost [--today|--week|--days N] [--json]   各 session 花多少 token、約當多少錢、動了多久
//   orbit cost tasks [--days N]                      各派工單的花費
//   orbit cost weekly [--save]                       這週摘要（Markdown；--save 存到 board/cost/week-日期.md）
enum CostCLI {
    static func name(_ sid: String) -> String { NicknameStore.get(sid)?.name ?? String(sid.prefix(8)) }

    static func run(_ args: [String]) -> Int32 {
        var a = Array(args.dropFirst())
        let sub = (a.first.map { !$0.hasPrefix("-") } ?? false) ? a.removeFirst() : "sessions"
        func value(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        let now = Date(), cal = Calendar.current
        let days = a.contains("--week") ? 7 : max(1, Int(value("--days") ?? "") ?? 1)
        let from = cal.startOfDay(for: now).addingTimeInterval(-Double(days - 1) * 86400)
        let files = CostLog.refresh(since: min(from, now.addingTimeInterval(-8 * 86400)))
        switch sub {
        case "sessions":
            let rows = CostLog.sum(files, from: from, to: now.addingTimeInterval(60)).values.sorted { $0.usd > $1.usd }
            if a.contains("--json") {
                let o = rows.map { ["session": $0.session, "name": name($0.session), "usd": ($0.usd * 100).rounded() / 100, "tokens": $0.tokens, "minutes": $0.minutes, "cwd": $0.cwd ?? ""] as [String: Any] }
                print(String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self))
                return 0
            }
            let total = rows.reduce(0) { $0 + $1.usd }
            print("\(days == 1 ? "今天" : "最近 \(days) 天")合計 \(CostLog.money(total))、\(CostLog.tok(rows.reduce(0) { $0 + $1.tokens })) token、\(rows.count) 個 session（約當 API 牌價估算）")
            for r in rows {
                let proj = r.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                print("  \(name(r.session).padding(toLength: 12, withPad: " ", startingAt: 0)) \(CostLog.money(r.usd).padding(toLength: 8, withPad: " ", startingAt: 0)) \(CostLog.tok(r.tokens).padding(toLength: 7, withPad: " ", startingAt: 0)) 動了 \(CostLog.dur(r.minutes))  \(proj)")
            }
            return 0
        case "tasks":
            let ts = CaptainStore.tasks().filter { $0.createdAt >= from }
            let rows = ts.compactMap { t in CostLog.task(t, files: files, now: now).map { (t, $0) } }.sorted { $0.1.usd > $1.1.usd }
            if rows.isEmpty { print("\(days == 1 ? "今天" : "最近 \(days) 天")沒有派工單的花費紀錄。"); return 0 }
            for (t, c) in rows { print("  \(t.id)  \(t.title ?? String(t.text.prefix(14)))  \(t.to)  \(CostLog.money(c.usd))  動了 \(CostLog.dur(c.minutes))  \(t.state.title)") }
            return 0
        case "weekly":
            let md = CostLog.weekly(files, end: now, names: name, tasks: CaptainStore.tasks())
            if a.contains("--save") {
                let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
                let u = CostLog.dir.appendingPathComponent("week-\(df.string(from: now)).md")
                try? FileManager.default.createDirectory(at: CostLog.dir, withIntermediateDirectories: true)
                do { try md.write(to: u, atomically: true, encoding: .utf8); print(u.path) } catch { FileHandle.standardError.write(Data("寫不進 \(u.path)\n".utf8)); return 1 }
            } else { print(md) }
            return 0
        default:
            FileHandle.standardError.write(Data("用法：orbit cost [--today|--week|--days N] [--json]｜orbit cost tasks [--days N]｜orbit cost weekly [--save]\n".utf8)); return 1
        }
    }
}
