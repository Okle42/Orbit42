import Foundation
import Testing
@testable import Orbit42Core

// 11-28 B 組⑤：花費紀錄。用暫存資料夾裡的假 transcript，不讀真的紀錄
// （例外：ORBIT_REAL_COST=1 時多跑一項「今天各 session」唯讀試算，只印出來、不寫快取到真的資料夾）。
@Suite("花費紀錄（CostLog）")
struct CostLogTests {
    func line(_ id: String, _ ts: String, model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0, w1h: Int = 0, read: Int = 0, speed: String = "standard") -> String {
        """
        {"type":"assistant","timestamp":"\(ts)","cwd":"/w/proj","message":{"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(w1h),"cache_read_input_tokens":\(read),"cache_creation":{"ephemeral_1h_input_tokens":\(w1h),"ephemeral_5m_input_tokens":0},"speed":"\(speed)"}}}
        """
    }

    @Test("價錢：Opus 5.5 輸入 $4、輸出 $20、1 小時快取寫入 2 倍、讀取 $0.2；fast 2 倍")
    func price() {
        let u = CostLog.Usage(input: 1_000_000, output: 1_000_000, write1h: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(u.usd("claude-opus-5-5") - (4 + 20 + 8 + 0.2)) < 1e-9)
        var f = u; f.fast = true
        #expect(abs(f.usd("claude-opus-5-5") - 2 * 32.2) < 1e-9)
        #expect(abs(CostLog.Usage(output: 1_000_000).usd("claude-haiku-5-5") - 0.5) < 1e-9)
        #expect(CostLog.price("claude-sonnet-5-5").input == 2 && CostLog.price("claude-sonnet-5").cacheRead == 0.2)
        #expect(CostLog.price("某個新模型").input == 4)        // 認不得照 Opus 5.5
    }

    @Test("同一則回覆出現好幾行只算一次；分鐘桶、動了幾分鐘")
    func parseDedup() {
        let s = [line("m1", "2026-11-28T01:00:05.000Z", input: 10, output: 100),
                 line("m1", "2026-11-28T01:00:06.000Z", input: 10, output: 100),        // 同一則的第二個內容區塊
                 line("m2", "2026-11-28T01:00:40.000Z", output: 1000, read: 50_000),
                 line("m3", "2026-11-28T01:07:00.000Z", output: 500),
                 "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}"].joined(separator: "\n")
        let fc = CostLog.parse(Data(s.utf8), session: "S1")
        #expect(fc.minutes.count == 2 && fc.cwd == "/w/proj")
        let sum = CostLog.sum(["a": fc], from: .distantPast, to: .distantFuture)["S1"]
        #expect(sum?.output == 1600 && sum?.tokens == 10 + 100 + 1000 + 50_000 + 500 && sum?.minutes == 2)
        let want = (10.0 * 4 + 1600 * 20 + 50_000 * 0.2) / 1e6
        #expect(abs((sum?.usd ?? 0) - want) < 1e-9)
    }

    @Test("掃資料夾：子 agent 算在主 session、沒變的檔不重讀、時段與派工單加總")
    func refreshAndTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cost-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("projects/-w-proj")
        try FileManager.default.createDirectory(at: proj.appendingPathComponent("S1/subagents"), withIntermediateDirectories: true)
        try line("a", "2026-11-28T02:00:00.000Z", output: 1_000_000).write(to: proj.appendingPathComponent("S1.jsonl"), atomically: true, encoding: .utf8)
        try line("b", "2026-11-28T02:30:00.000Z", model: "claude-haiku-5-5", output: 1_000_000).write(to: proj.appendingPathComponent("S1/subagents/agent-x.jsonl"), atomically: true, encoding: .utf8)
        try line("c", "2026-11-28T05:00:00.000Z", output: 1_000_000).write(to: proj.appendingPathComponent("S2.jsonl"), atomically: true, encoding: .utf8)
        let cache = root.appendingPathComponent("cache.json")
        let files = CostLog.refresh(root: root.appendingPathComponent("projects"), cache: cache, since: .distantPast)
        #expect(files.count == 3 && FileManager.default.fileExists(atPath: cache.path))
        let all = CostLog.sum(files, from: .distantPast, to: .distantFuture)
        #expect(abs((all["S1"]?.usd ?? 0) - 20.5) < 1e-9 && abs((all["S2"]?.usd ?? 0) - 20) < 1e-9)
        // 第二次：快取命中（同樣結果）
        #expect(CostLog.refresh(root: root.appendingPathComponent("projects"), cache: cache, since: .distantPast) == files)

        let iso = ISO8601DateFormatter()
        var t = CaptainTask(id: "T2611280200", from: "C", to: "Tina", toSession: "S1", project: nil, text: "做 B 組")
        t.createdAt = iso.date(from: "2026-11-28T02:10:00Z")!; t.updatedAt = iso.date(from: "2026-11-28T03:00:00Z")!; t.state = .done
        let c = CostLog.task(t, files: files)
        #expect(abs((c?.usd ?? 0) - 0.5) < 1e-9)             // 只有 02:30 那筆子 agent 落在派工時段
        let md = CostLog.weekly(files, end: iso.date(from: "2026-11-28T12:00:00Z")!, names: { $0 == "S1" ? "Tina" : $0 }, tasks: [t])
        #expect(md.contains("Tina") && md.contains("T2611280200") && md.contains("合計 **$40**"))
    }

    @Test("真實紀錄唯讀試算（ORBIT_REAL_COST=1 才跑）", .enabled(if: ProcessInfo.processInfo.environment["ORBIT_REAL_COST"] == "1"))
    func realToday() {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("cost-real-\(UUID().uuidString).json")
        let start = Calendar.current.startOfDay(for: Date())
        let files = CostLog.refresh(root: root, cache: cache, since: start)
        let rows = CostLog.sum(files, from: start, to: Date().addingTimeInterval(60)).values.sorted { $0.usd > $1.usd }
        print("REAL 今天 \(rows.count) 個 session，合計 \(CostLog.money(rows.reduce(0) { $0 + $1.usd }))")
        for r in rows.prefix(15) { print("REAL \(r.session.prefix(8)) \(CostLog.money(r.usd)) \(CostLog.tok(r.tokens)) 動了 \(CostLog.dur(r.minutes)) \(r.cwd ?? "")") }
        #expect(!rows.isEmpty)
    }
}
