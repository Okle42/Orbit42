import Foundation
import Testing

// 11-28 Fiona2：board/installed.json 停在 11-23（ShoWork42 安裝器留下、改名後沒人寫）
// ⇒ scripts/installed_record.py：build_app.sh 裝好、restart_app.sh 重開成功時更新；commit 一律從 App 的 Info.plist 讀
@Suite("installed.json：打包裝好、重開時自動更新")
struct InstalledRecordTests {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/installed_record.py").path

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("instrec-\(UUID().uuidString)")
    var app: String { dir.appendingPathComponent("Orbit42.app").path }
    var json: String { dir.appendingPathComponent("board/installed.json").path }

    func fakeApp(commit: String?) throws {
        let c = dir.appendingPathComponent("Orbit42.app/Contents")
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        var p: [String: Any] = ["CFBundleIdentifier": "ai.okle42.orbit42"]
        if let commit { p["OrbitGitCommit"] = commit }
        try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0).write(to: c.appendingPathComponent("Info.plist"))
    }

    @discardableResult
    func run(_ args: [String]) throws -> Int32 {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        t.arguments = ["-I", Self.script] + args
        t.environment = ["ORBIT_INSTALLED": json, "PATH": "/usr/bin:/bin"]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        try t.run(); t.waitUntilExit()
        return t.terminationStatus
    }

    func read() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: json))) as! [String: Any]
    }

    @Test("裝好：記 App 裡的 commit、誰、從哪個資料夾、有沒有強制；上一版留在 previous")
    func build() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeApp(commit: "aaaa111")
        #expect(try run(["build", "--app", app, "--who", "Tina", "--root", "/repo"]) == 0)
        var d = try read()
        #expect(d["commit"] as? String == "aaaa111")
        #expect(d["who"] as? String == "Tina")
        #expect(d["root"] as? String == "/repo")
        #expect(d["forced"] as? Bool == false)
        #expect(d["previous"] == nil)

        try fakeApp(commit: "bbbb222")
        try run(["build", "--app", app, "--who", "Fiona2", "--forced", "救急"])
        d = try read()
        #expect(d["commit"] as? String == "bbbb222")
        #expect(d["forced"] as? Bool == true)
        #expect(d["forceReason"] as? String == "救急")
        #expect((d["previous"] as? [String: Any])?["commit"] as? String == "aaaa111")
    }

    @Test("重開：補上誰重開、何時、程序編號，裝的那筆不動")
    func restart() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeApp(commit: "aaaa111")
        try run(["build", "--app", app, "--who", "Tina"])
        try run(["restart", "--app", app, "--who", "Captain", "--pid", "4242"])
        let d = try read()
        #expect(d["commit"] as? String == "aaaa111")
        #expect(d["who"] as? String == "Tina")
        #expect(d["restartedBy"] as? String == "Captain")
        #expect(d["pid"] as? Int == 4242)
        #expect(d["restartedAt"] is String)
    }

    @Test("包被別的方式換過（不是 build_app.sh 裝的）：重開時以 Info.plist 為準，舊的留在 previous")
    func restartAfterOtherSwap() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeApp(commit: "aaaa111")
        try run(["build", "--app", app, "--who", "Tina"])
        try fakeApp(commit: "cccc333")
        try run(["restart", "--app", app, "--who", "Captain", "--pid", "1"])
        let d = try read()
        #expect(d["commit"] as? String == "cccc333")
        #expect(d["who"] == nil || d["who"] is NSNull)
        #expect((d["previous"] as? [String: Any])?["commit"] as? String == "aaaa111")
    }

    @Test("寫不進去也不擋打包重開：exit 0")
    func failSoft() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try fakeApp(commit: "aaaa111")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("board"))          // board 是檔案不是資料夾 ⇒ 寫不進去
        #expect(try run(["build", "--app", app]) == 0)
    }
}
