import XCTest
@testable import Orbit42

final class PtyTests: XCTestCase {
    /// The terminal really is a TTY (programs like Claude Code need one) and output comes back
    func testRunsInTTYAndEchoes() throws {
        let done = expectation(description: "exit")
        var out = Data()
        let lock = NSLock()
        guard let p = Pty(command: "test -t 0 && echo TTY-OK; stty size", cwd: NSTemporaryDirectory(), cols: 77, rows: 21) else { return XCTFail("no pty") }
        p.onData = { d in lock.lock(); out.append(d); lock.unlock() }
        p.onExit = { _ in done.fulfill() }
        wait(for: [done], timeout: 15)
        lock.lock(); let s = String(decoding: out, as: UTF8.self); lock.unlock()
        XCTAssertTrue(s.contains("TTY-OK"), s)
        XCTAssertTrue(s.contains("21 77"), s)
    }

    /// Satellites must not inherit the launching Claude session's markers
    func testDropsClaudeSessionMarkers() throws {
        setenv("CLAUDE_CODE_CHILD_SESSION", "1", 1); setenv("CLAUDECODE", "1", 1)
        let done = expectation(description: "exit")
        var out = Data(); let lock = NSLock()
        guard let p = Pty(command: "echo M=[${CLAUDE_CODE_CHILD_SESSION}${CLAUDECODE}]", cwd: NSTemporaryDirectory(), cols: 80, rows: 24) else { return XCTFail("no pty") }
        p.onData = { d in lock.lock(); out.append(d); lock.unlock() }
        p.onExit = { _ in done.fulfill() }
        wait(for: [done], timeout: 15)
        lock.lock(); let s = String(decoding: out, as: UTF8.self); lock.unlock()
        XCTAssertTrue(s.contains("M=[]"), s)
    }
}
