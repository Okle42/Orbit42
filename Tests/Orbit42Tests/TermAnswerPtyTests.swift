import XCTest
import Orbit42Core
@testable import Orbit42

/// 假的 Claude（python）跑在真的 PTY 裡：畫輸入框、收 bracketed paste、Enter 才寫進假的對話紀錄。不碰任何真的 session。
@MainActor
final class TermAnswerPtyTests: XCTestCase {
    static let fake = #"""
import sys, os, tty, json
mode, log = sys.argv[1], sys.argv[2]
tty.setraw(0)
buf = "草稿" if mode == "draft" else ""
def draw():
    top = "─" * 40 + " Fake1 ─"
    rows = ["Do you want to proceed?", "❯ 1. Yes", "Esc to cancel"] if mode == "menu" else [top, "❯ " + buf, "─" * 48]
    sys.stdout.write("\\x1b]9;" + json.dumps(rows) + "\\x07"); sys.stdout.flush()
def late(t):
    global buf
    buf += t; draw()
draw()
data = b""; first = True
while True:
    d = os.read(0, 4096)
    if not d: break
    open(log + ".raw", "ab").write(d)
    data += d
    if mode.startswith("cmd") and b"\\x1b[200~" not in data and not data.endswith(b"\\r") and b"\\x15" not in data:
        buf += data.decode() + ("x" if mode == "cmdextra" else ""); data = b""; draw()
    if mode == "cmd" and data.endswith(b"\\r") and buf == "/clear": open(log + ".new", "w").close()
    if mode == "slow" and first: first = False; import time; time.sleep(3)
    while b"\\x1b[200~" in data and b"\\x1b[201~" in data:
        a, rest = data.split(b"\\x1b[200~", 1); t, data = rest.split(b"\\x1b[201~", 1)
        if mode == "late": import threading; threading.Timer(2.0, late, [t.decode()]).start()
        elif mode == "half" or mode == "sticky": buf += t.decode()[:3]
        elif mode != "deaf": buf += t.decode()
        draw()
    if b"\\x15" in data:
        data = b""
        if mode != "sticky": buf = ""
        draw()
    if data.endswith(b"\\r"):
        data = b""
        if mode != "lost": open(log, "a").write(json.dumps({"type": "user", "message": {"role": "user", "content": buf}}) + "\\n")
        buf = ""; draw()
"""#.replacingOccurrences(of: "\\\\", with: "\\")

    func run(_ mode: String, text: String = "好，推上去（完整一句，超過四十個字也不能被剪掉，一路到句尾都要在，最後一個字是完）", sid: String = "s1",
             live: String = "s1", command: Bool = false, idle: Bool = true, unique: Bool = true, typing: Bool = false, markOK: Bool = true, busyAfterPaste: Bool = false, held: String = "") async throws -> (TermAnswer.Outcome, log: String, raw: Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let py = dir.appendingPathComponent("fake.py"), log = dir.appendingPathComponent("log.jsonl")
        try Self.fake.write(to: py, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let pty = try XCTUnwrap(Pty(command: "exec /usr/bin/python3 -I '\(py.path)' \(mode) '\(log.path)'", cwd: dir.path, cols: 100, rows: 30))
        let lock = NSLock(); nonisolated(unsafe) var out = Data()
        pty.onData = { d in lock.lock(); out.append(d); lock.unlock() }
        func screen() -> TermAnswer.Screen? {
            lock.lock(); let s = String(decoding: out, as: UTF8.self); lock.unlock()
            guard let a = s.range(of: "\u{1B}]9;", options: .backwards), let z = s.range(of: "\u{07}", range: a.upperBound..<s.endIndex),
                  let rows = try? JSONDecoder().decode([String].self, from: Data(s[a.upperBound..<z.lowerBound].utf8)) else { return nil }
            return .init(rows: rows.map { .init(text: $0, solid: $0) }, cursorRow: 1, cursorCol: 2, paste: true)
        }
        for _ in 0..<100 where screen() == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(screen())
        var wrote = false
        let io = TermAnswer.IO(target: { .init(sid: command && FileManager.default.fileExists(atPath: log.path + ".new") ? "s2" : live, name: "Fake1", idle: idle && !(busyAfterPaste && wrote), unique: unique) }, screen: { screen() }, mark: { markOK }, write: { wrote = true; pty.write($0) },
                               typing: { typing }, added: { try? Data(contentsOf: log) }, wait: { try? await Task.sleep(for: .seconds($0 / 4)) })
        let (r, replay) = TermAnswer.settle(await TermAnswer.send(text, to: sid, command: command, io: io), held: Data(held.utf8), safe: screen().map { TermAnswer.plain($0, name: "Fake1") } ?? false)
        if !replay.isEmpty { pty.write(replay) }
        try await Task.sleep(for: .milliseconds(200))
        let l = try String(contentsOf: log, encoding: .utf8), raw = (try? Data(contentsOf: URL(fileURLWithPath: log.path + ".raw"))) ?? Data()
        pty.hangup()
        return (r, l, raw)
    }

    func testTypesWholeAnswerOnce() async throws {
        let text = "好，推上去（完整一句，超過四十個字也不能被剪掉，一路到句尾都要在，最後一個字是完）"
        let (r, log, raw) = try await run("ok", text: text)
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(log.split(separator: "\n").count, 1)
        XCTAssertTrue(TermAnswer.confirmed(Data(log.utf8), text: text))
        XCTAssertEqual(raw.filter { $0 == 0x0D }.count, 1)
    }
    /// 草稿、選單、忙、同名、換了 session、正在打字：一個位元組都不寫
    func testWritesNothingWhenUnsure() async throws {
        for (m, live, idle, unique, typing) in [("draft", "s1", true, true, false), ("menu", "s1", true, true, false), ("ok", "s2", true, true, false),
                                                ("ok", "s1", false, true, false), ("ok", "s1", true, false, false), ("ok", "s1", true, true, true)] {
            let (r, log, raw) = try await run(m, live: live, idle: idle, unique: unique, typing: typing)
            guard case .notStarted = r else { XCTFail("\(m) \(r)"); continue }
            XCTAssertTrue(raw.isEmpty && log.isEmpty, m)
        }
    }
    func testWritesNothingWithoutMark() async throws {
        let (r, log, raw) = try await run("ok", markOK: false)
        guard case .notStarted = r else { return XCTFail("\(r)") }
        XCTAssertTrue(raw.isEmpty && log.isEmpty)
    }
    /// 貼了卻沒出現在框裡：不按 Enter、不回 notStarted（不然會再走訊息送第二次）
    func testNoEnterIfPasteNotSeen() async throws {
        // 沒出現、只出現一半：清得掉清不掉都算沒確認到（寫過就不改走訊息）。都不按 Enter
        for m in ["deaf", "half", "sticky", "late", "slow"] {
            let (r, log, raw) = try await run(m)
            guard case .unsure(let why) = r else { XCTFail("\(m) \(r)"); continue }
            XCTAssertTrue(why.contains("可能有字"))
            XCTAssertTrue(log.isEmpty && !raw.contains(0x0D), m)
        }
    }
    /// Gavin5 ③ a、b：貼上沒出現／已在框裡但 Enter 前變忙，扣住的 abc⏎ 不能把卡片的字送出去
    func testHeldEnterNeverSubmitsCard() async throws {
        for (m, busy) in [("deaf", false), ("sticky", false), ("ok", true)] {
            let (r, log, raw) = try await run(m, busyAfterPaste: busy, held: "abc\r")
            XCTAssertFalse(TermAnswer.confirmed(Data(log.utf8), text: "好，推上去（完整一句，超過四十個字也不能被剪掉，一路到句尾都要在，最後一個字是完）"), m)
            if case .unsure(let why) = r {
                XCTAssertTrue(why.contains("「abc⏎」沒有送進去"), why); XCTAssertTrue(!raw.contains(0x0D) && log.isEmpty, m)
            } else { XCTFail("\(m) \(r)") }
        }
    }
    func testUnsureIfNotInConversation() async throws {
        let (r, _, raw) = try await run("lost")
        guard case .unsure = r else { return XCTFail("\(r)") }
        XCTAssertEqual(raw.filter { $0 == 0x0D }.count, 1)
    }
    /// 自動 /clear：直接打（不是貼上）、Enter 一次、換了 session 才算；框裡多一個字就不按 Enter；草稿／忙／正在打字一個字都不寫
    func testClearCommand() async throws {
        let (r, _, raw) = try await run("cmd", text: "/clear", command: true)
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "/clear\r")
        let (x, _, rawX) = try await run("cmdextra", text: "/clear", command: true)
        if case .sent = x { XCTFail("多字不能送") }
        XCTAssertFalse(rawX.contains(0x0D))
        let (n, _, _) = try await run("cmdstuck", text: "/clear", command: true)
        guard case .unsure = n else { return XCTFail("\(n)") }
        for (m, idle, typing) in [("draft", true, false), ("menu", true, false), ("cmd", false, false), ("cmd", true, true)] {
            let (r, _, raw) = try await run(m, text: "/clear", command: true, idle: idle, typing: typing)
            guard case .notStarted = r else { XCTFail("\(m) \(r)"); continue }
            XCTAssertTrue(raw.isEmpty, m)
        }
    }
    /// 真的 claude --bg（拋棄式）：沒開衛星也要能悄悄接上並 /clear。平常略過：ORBIT_E2E_SID=<sid>
    func testRealBackgroundClear() async throws {
        guard let sid = ProcessInfo.processInfo.environment["ORBIT_E2E_SID"] else { throw XCTSkip("要給 ORBIT_E2E_SID") }
        let h = Orbit42.Host(); h.startTimers()
        var last: TermAnswer.Outcome?
        for _ in 0..<8 {
            last = nil
            XCTAssertTrue(h.typeClear(sid, still: { true }) { last = $0 })
            for _ in 0..<400 where last == nil { try await Task.sleep(for: .milliseconds(100)) }
            print("e2e", last as Any)
            if last != .sent, let id = h.views.keys.first, let j = try? await h.views[id]?.evaluateJavaScript("window.orbitScreen(\"\(id)\")") as? String { print("e2e-screen", j) }
            if last == .sent { return }
            try await Task.sleep(for: .seconds(6))
        }
        XCTFail("\(String(describing: last))")
    }
}
