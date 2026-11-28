import Foundation
import Testing
@testable import Orbit42Core

// 11-28 B 組③：從過去紀錄整理建議。haiku 用假的（固定回答），存檔用暫存資料夾。
// ORBIT_REAL_LEARN=1：拿真的交流板／派工單／指正紀錄跑一次真的 haiku（唯讀收集；結果寫到 ORBIT_REAL_LEARN_OUT，沒給就寫暫存檔）。
@Suite("從紀錄變聰明（Lessons）", .serialized)
struct LessonsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("learn-\(UUID().uuidString).json") }

    func sample() -> [Lessons.Source] {
        let posts = [B1Post(id: 7, at: now - 3600, sid: "s", name: "Milo", project: "Orbit42", text: "swift test 整包跑會撞記憶體，先 --filter")]
        var t = CaptainTask(id: "T2611280100", from: "C", to: "Xena", project: nil, text: "修複製貼上")
        t.summary = "改好了，但忘了先發開工卡"; t.updatedAt = now - 1800
        t.notes = [KengNote(text: "答了要自動知道，不是人工按", at: now - 600, card: "Xena", via: "Orbit42 卡片")]
        return Lessons.sources(since: now - 86400, posts: posts, tasks: [t], memories: [("feedback_x.md", now - 100, "type: feedback\n不要用代號問")],
                               commits: [(now - 50, "答案卡自動收（Keng：答了要自動知道）"), (now - 40, "整理 README")])
    }

    @Test("收集：交流板、派工回報、Keng 原話、指正紀錄、有 Keng 的 commit；舊的、無關的不收")
    func collect() {
        let s = sample()
        #expect(s.map(\.tag) == ["交流板 #7 Milo", "派工 T2611280100 Xena 回報", "Keng 原話（派工 T2611280100）", "指正紀錄 feedback_x.md", "commit"])
        let p = Lessons.prompt(s, existing: [])
        #expect(p.contains("[交流板 #7 Milo｜") && p.contains("只輸出 JSON 陣列"))
    }

    let fake = """
    好的，以下是建議：
    ```json
    [{"kind":"派工提醒","title":"測試先 filter","text":"swift test 先用 --filter 跑相關的，不要整包","why":"Milo 撞過記憶體","evidence":["交流板 #7 Milo"],"target":null},
     {"kind":"改規則","title":"答案卡要自動收","text":"終端機回答就當答了","why":"Keng 指正","evidence":["Keng 原話（派工 T2611280100）"],"target":"hook_answer_card.py"},
     {"kind":"改 skill","title":"沒出處","text":"亂講的","why":"","evidence":[],"target":"x"},
     {"kind":"不認得","title":"x","text":"y","evidence":["commit"]}]
    ```
    """

    @Test("解析：抓 JSON、沒出處或種類不對的丟掉、存成待核可")
    func scanAndParse() throws {
        let u = tmp()
        guard case .success(let new) = Lessons.scan(sample(), run: { _ in fake }, now: now, url: u) else { Issue.record("scan 失敗"); return }
        #expect(new.map(\.kind) == [.reminder, .rule] && new.allSatisfy { $0.state == .pending })
        #expect(new[1].target == "hook_answer_card.py" && new[0].target == nil)
        #expect(Lessons.all(u).count == 2)
        #expect(Lessons.reminders(Lessons.all(u)).isEmpty)          // 沒核可就不生效
        if case .success = Lessons.scan([], run: { _ in fake }, url: u) { Issue.record("沒紀錄應該失敗") }
        if case .success = Lessons.scan(sample(), run: { _ in "我不知道" }, url: u) { Issue.record("看不懂應該失敗") }
        #expect(Lessons.all(u).count == 2)
    }

    @Test("核可後：派工提醒附進派工單全文；不採用的不附；規則類不自動改")
    func approveFlow() throws {
        let u = tmp()
        guard case .success(let new) = Lessons.scan(sample(), run: { _ in fake }, now: now, url: u) else { return }
        #expect(Lessons.decide(new[0].id.lowercased(), approve: true, now: now, url: u)?.state == .approved)
        #expect(Lessons.decide(new[1].id, approve: true, now: now, url: u)?.state == .approved)
        #expect(Lessons.decide("LZZZZ", approve: true, url: u) == nil)
        let r = Lessons.reminders(Lessons.all(u))
        #expect(r == ["swift test 先用 --filter 跑相關的，不要整包"])        // 規則類不進派工提醒
        let t = CaptainTask(id: "T2611281200", from: "C", to: "Tina", text: "做 B 組\n細節")
        let m = Captain.message(t, orbit: "orbit", reminders: r)
        #expect(m.contains("這次要注意") && m.contains("・swift test 先用 --filter"))
        #expect(!Captain.message(t, orbit: "orbit").contains("這次要注意"))
        _ = Lessons.decide(new[0].id, approve: false, url: u)
        #expect(Lessons.reminders(Lessons.all(u)).isEmpty)
    }

    @Test("真的跑一次（ORBIT_REAL_LEARN=1 才跑）", .enabled(if: ProcessInfo.processInfo.environment["ORBIT_REAL_LEARN"] == "1"))
    func real() {
        let env = ProcessInfo.processInfo.environment
        let since = Date().addingTimeInterval(-2 * 86400)
        var commits: [(Date, String)] = []
        if let repo = env["ORBIT_REAL_LEARN_REPO"] {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo, "log", "--since=\(Int(since.timeIntervalSince1970))", "--format=%ct\t%s", "-n", "300"]
            p.standardOutput = pipe; try? p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            commits = String(decoding: d, as: UTF8.self).split(separator: "\n").compactMap { l in
                let x = l.split(separator: "\t", maxSplits: 1); return x.count == 2 ? Double(x[0]).map { (Date(timeIntervalSince1970: $0), String(x[1])) } : nil }
        }
        let src = Lessons.sources(since: since, posts: B1Board.all(), tasks: CaptainStore.tasks(), memories: Lessons.feedbackMemories(since: since), commits: commits)
        print("REAL 紀錄 \(src.count) 筆")
        let out = env["ORBIT_REAL_LEARN_OUT"].map { URL(fileURLWithPath: $0) } ?? tmp()
        switch Lessons.scan(src, run: Lessons.haiku, url: out) {
        case .failure(let e): Issue.record("REAL 失敗：\(e.message)")
        case .success(let new):
            print("REAL 新建議 \(new.count) 條 → \(out.path)")
            for s in new { print("REAL " + Lessons.line(s).replacingOccurrences(of: "\n", with: "\nREAL ")) }
            #expect(new.count >= 5)
        }
    }
}
