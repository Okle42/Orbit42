import XCTest
import ShoWorkCore
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
draw()
data = b""
while True:
    d = os.read(0, 4096)
    if not d: break
    open(log + ".raw", "ab").write(d)
    data += d
    while b"\\x1b[200~" in data and b"\\x1b[201~" in data:
        a, rest = data.split(b"\\x1b[200~", 1); t, data = rest.split(b"\\x1b[201~", 1)
        if mode != "deaf": buf += t.decode()
        draw()
    if data.endswith(b"\\r"):
        data = b""
        if mode != "lost": open(log, "a").write(json.dumps({"type": "user", "message": {"role": "user", "content": buf}}) + "\\n")
        buf = ""; draw()
"""#.replacingOccurrences(of: "\\\\", with: "\\")

    func run(_ mode: String, text: String = "好，推上去（完整一句，超過四十個字也不能被剪掉，一路到句尾都要在，最後一個字是完）", sid: String = "s1",
             live: String = "s1", idle: Bool = true, unique: Bool = true, typing: Bool = false) async throws -> (TermAnswer.Outcome, log: String, raw: Data) {
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
        let io = TermAnswer.IO(target: { .init(sid: live, name: "Fake1", idle: idle, unique: unique) }, screen: { screen() }, write: { pty.write($0) },
                               typing: { typing }, added: { try? Data(contentsOf: log) }, wait: { try? await Task.sleep(for: .seconds($0 / 4)) })
        let r = await TermAnswer.send(text, to: sid, io: io)
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
    /// 貼了卻沒出現在框裡：不按 Enter、不回 notStarted（不然會再走訊息送第二次）
    func testNoEnterIfPasteNotSeen() async throws {
        let (r, log, raw) = try await run("deaf")
        guard case .unsure = r else { return XCTFail("\(r)") }
        XCTAssertTrue(log.isEmpty && !raw.contains(0x0D))
    }
    func testUnsureIfNotInConversation() async throws {
        let (r, _, raw) = try await run("lost")
        guard case .unsure = r else { return XCTFail("\(r)") }
        XCTAssertEqual(raw.filter { $0 == 0x0D }.count, 1)
    }
}
