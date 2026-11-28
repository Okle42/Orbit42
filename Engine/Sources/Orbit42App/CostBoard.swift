import Foundation
import Orbit42Core

// 11-28 B 組⑤：戰情卡每列的「今天花費」。背景每 5 分鐘重算一次（CostLog 有快取，沒變的檔不重讀），
// 球體 push 時只讀記憶體裡的結果，不卡畫面。週一第一次算的時候順便存上週摘要到 board/cost/week-日期.md。
final class CostBoard: @unchecked Sendable {
    static let shared = CostBoard()
    private let lock = NSLock()
    private var today: [String: CostLog.SessionCost] = [:]
    private var running = false
    private var lastRun = Date.distantPast
    private var lastWeekly: String?

    /// 這個 session 今天的花費（還沒算好就 nil）
    func cost(_ sid: String) -> CostLog.SessionCost? {
        lock.lock(); defer { lock.unlock() }
        kick()
        return today[sid]
    }

    private func kick() {       // 已在 lock 裡
        guard !running, Date().timeIntervalSince(lastRun) > 300 else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let now = Date(), cal = Calendar.current, start = cal.startOfDay(for: now)
            let files = CostLog.refresh(since: now.addingTimeInterval(-8 * 86400))
            let t = CostLog.sum(files, from: start, to: now.addingTimeInterval(60))
            let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
            let key = df.string(from: now)
            var weekly: String?
            if cal.component(.weekday, from: now) == 2 {          // 週一：存上週（到昨天）
                let u = CostLog.dir.appendingPathComponent("week-\(key).md")
                if !FileManager.default.fileExists(atPath: u.path) {
                    let md = CostLog.weekly(files, end: start.addingTimeInterval(-1), names: { NicknameStore.get($0)?.name ?? String($0.prefix(8)) }, tasks: CaptainStore.tasks())
                    try? md.write(to: u, atomically: true, encoding: .utf8)
                    weekly = key
                }
            }
            lock.lock(); today = t; running = false; lastRun = Date(); if let weekly { lastWeekly = weekly }; lock.unlock()
        }
    }
}
