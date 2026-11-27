import Foundation
import Orbit42Core

// `orbit seccheck [--card] [--json] [--wait] [--accept-network] [--open]`：本機資安體檢（Orbit42Core/SecCheck.swift，跟 App 小視窗同一套）。
//   --card            結果發成卡片（綠燈只寫數量，黃紅燈附一句白話）；要在 Claude Code 裡跑
//   --json            印 JSON
//   --wait            等第 4 項（待裝更新，背景查）跑完再出結果，最多 3 分鐘
//   --accept-network  目前的 DNS／代理設定是我設的：存成已確認的基準
//   --open            叫 Orbit42 打開體檢小視窗
// 只看不改：只有 --accept-network 會寫 Orbit42 自己的基準檔，系統設定一律不動。
enum SecCheckCLI {
    static func run(_ args: [String], orbit: String) -> Int32 {
        let a = Set(args.dropFirst())
        if a.contains("--open") {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("ai.okle42.orbit42.seccheck"), object: nil, userInfo: nil, deliverImmediately: true)
            print("已叫 Orbit42 打開本機資安體檢小視窗（Orbit42 沒開就不會出現）")
            return 0
        }
        if a.contains("--accept-network") {
            SecCheck.acceptNetworkBaseline()
            print("已把目前的 DNS／代理設定存成你確認過的基準；之後被改才會亮紅燈")
        }
        if a.contains("--wait") {
            SecCheck.kickUpdates()
            if !SecCheck.waitUpdates(timeout: 180) { FileHandle.standardError.write(Data("待裝更新 3 分鐘內沒查完，先出其他項目\n".utf8)) }
        }
        let r = SecCheck.run()
        if a.contains("--json") {
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
            print(String(decoding: (try? e.encode(r)) ?? Data(), as: UTF8.self))
        } else {
            let mark: [SecLevel: String] = [.ok: "🟢", .warn: "🟡", .bad: "🔴", .info: "ℹ️ ", .pending: "⏳"]
            print("本機資安體檢　\(String(format: "%.1f", r.seconds)) 秒　綠 \(r.count(.ok))・黃 \(r.count(.warn))・紅 \(r.count(.bad))・列出 \(r.count(.info))・檢查中 \(r.count(.pending))")
            for i in r.items {
                print("\(mark[i.level] ?? "")\(i.no). \(i.title)：\(i.detail)")
                if let w = i.why, i.level != .ok { print("    → \(w)") }
            }
        }
        if a.contains("--card") {
            let st = r.worst == .ok && r.count(.pending) == 0 ? "done" : "review"
            let p = Process(); p.executableURL = URL(fileURLWithPath: orbit)
            p.arguments = ["card", "--doing", "本機資安體檢", "--status", st, "--progress", "100", "--confidence", "90",
                           "--summary", r.cardSummary, "--how", "orbit seccheck（macOS 內建指令＋CoreWLAN，只看不改）"]
            do { try p.run(); p.waitUntilExit() } catch { FileHandle.standardError.write(Data("發卡失敗：\(error)\n".utf8)); return 1 }
            return p.terminationStatus
        }
        return 0
    }
}
