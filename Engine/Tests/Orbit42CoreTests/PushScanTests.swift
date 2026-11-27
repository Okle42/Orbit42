import Foundation
import Testing
@testable import Orbit42Core

// 11-28 資安體檢第 12 項驗收：假 repo＋本機假遠端（bare repo），放明顯是假的測試金鑰 ⇒ push 被擋；放行後才推得上去。
// 全程在暫存資料夾，不碰任何真的 repo、不連網路、不碰真的收件匣（放行單用假的 consume／open）。
@Suite("PushScan", .serialized)
struct PushScanTests {
    static func git(_ dir: String, _ a: [String]) -> (code: Int32, out: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", dir] + a
        p.standardOutput = pipe; p.standardError = pipe
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        p.environment = env
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    /// 暫存資料夾裡的 work（有 origin＝本機 bare repo）
    func makeRepo(_ content: String) throws -> (work: String, bare: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pushscan-\(UUID().uuidString)").path
        let work = root + "/work", bare = root + "/remote.git"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        _ = Self.git(root, ["init", "-q", "--bare", bare])
        _ = Self.git(work, ["init", "-q", "-b", "main"])
        _ = Self.git(work, ["config", "user.email", "test@example.invalid"]); _ = Self.git(work, ["config", "user.name", "Test"])
        _ = Self.git(work, ["remote", "add", "origin", bare])
        try "hello\n".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
        _ = Self.git(work, ["add", "."]); _ = Self.git(work, ["commit", "-qm", "init"])
        _ = Self.git(work, ["push", "-q", "origin", "main"])
        try content.write(toFile: work + "/config.txt", atomically: true, encoding: .utf8)
        _ = Self.git(work, ["add", "."]); _ = Self.git(work, ["commit", "-qm", "add config"])
        return (work, bare)
    }

    // 明顯是假的：只為了長得像 Anthropic 金鑰的格式
    let fakeKey = "api_key = sk-" + "ant-TESTONLY-THIS-IS-NOT-A-REAL-KEY-0000"

    @Test("假金鑰：push 被擋、可以用放行單；放行後才推得上去")
    func blockThenRelease() throws {
        let (work, bare) = try makeRepo(fakeKey + "\n")
        var e = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: [], strict: [])
        #expect(e.verdict == .block && e.secret && e.contentOnly == true)

        // 第一次：沒放行 ⇒ 開單、回擋下說明
        var opened: [String] = []
        let why = PushGuard.gate(&e, consume: { _ in false }, open: { fp, _ in opened.append(fp); return "BTEST" })
        #expect(why?.contains("放行！BTEST") == true && e.verdict == .block)
        #expect(opened == [PushGuard.releaseFingerprint(e)])
        // 被擋就不推：遠端還是只有 init
        #expect(Self.git(bare, ["rev-list", "--count", "main"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

        // Keng 打「放行！BTEST」之後：同一個指紋 consume 成功 ⇒ 放行
        var e2 = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: [], strict: [])
        let fp = PushGuard.releaseFingerprint(e2)
        #expect(PushGuard.gate(&e2, consume: { $0 == fp }, open: { _, _ in "BNEW" }) == nil)
        #expect(e2.verdict == .ok)
        #expect(Self.git(work, ["push", "-q", "origin", "main"]).code == 0)
        #expect(Self.git(bare, ["rev-list", "--count", "main"]).out.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("改了 commit 指紋就不同：舊放行單不能拿來推新內容")
    func newHeadNeedsNewRelease() throws {
        let (work, _) = try makeRepo(fakeKey + "\n")
        let e1 = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: [], strict: [])
        try "more\n".write(toFile: work + "/b.txt", atomically: true, encoding: .utf8)
        _ = Self.git(work, ["add", "."]); _ = Self.git(work, ["commit", "-qm", "more"])
        var e2 = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: [], strict: [])
        let old = PushGuard.releaseFingerprint(e1)
        #expect(old != PushGuard.releaseFingerprint(e2))
        #expect(PushGuard.gate(&e2, consume: { $0 == old }, open: { _, _ in "BNEW" }) != nil)
        #expect(e2.verdict == .block)
    }

    @Test("客戶關鍵字：私人 repo 也擋（以前只提醒）")
    func keywordBlocks() throws {
        let (work, _) = try makeRepo("報價給 DemoClientX\n")
        let e = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: ["DemoClientX"], strict: [])
        #expect(e.verdict == .block && e.contentOnly == true && !e.secret)
    }

    @Test("force push main 這類結構問題不能用放行單")
    func structuralNotReleasable() throws {
        let (work, _) = try makeRepo(fakeKey + "\n")
        var e = PushGuard.check(PushCall(dir: work, args: ["--force", "origin", "main"]), git: Self.git, keywords: [], strict: [])
        #expect(e.verdict == .block && e.contentOnly == false)
        #expect(PushGuard.gate(&e, consume: { _ in true }, open: { _, _ in "B" }) == nil)
        #expect(e.verdict == .block)
    }

    @Test("沒問題的 push 照常")
    func clean() throws {
        let (work, _) = try makeRepo("just text\n")
        let e = PushGuard.check(PushCall(dir: work, args: ["origin", "main"]), git: Self.git, keywords: ["DemoClientX"], strict: [])
        #expect(e.verdict == .ok && e.contentOnly == nil)
    }
}
