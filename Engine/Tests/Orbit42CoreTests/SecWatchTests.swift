import Foundation
import Testing
@testable import Orbit42Core

// 11-28 資安體檢第二階段：開機項目／權限跟上次比、自動跑沒變化不通知
@Suite("SecWatch")
struct SecWatchTests {
    @Test("開機項目：讀資料夾裡的 plist；新增測試項目要抓到、紅燈")
    func startup() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sw-\(UUID().uuidString)/Library/LaunchAgents").path
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try "<plist/>".write(toFile: d + "/com.example.a.plist", atomically: true, encoding: .utf8)
        let base = SecCheck.startupItems(dirs: [d])
        #expect(base.count == 1)
        #expect(SecCheck.startupItem(now: base, base: nil).level == .info)                 // 第一次只記錄
        #expect(SecCheck.startupItem(now: base, base: base).level == .ok)
        try "<plist/>".write(toFile: d + "/ai.okle42.sigtest.plist", atomically: true, encoding: .utf8)
        let now = SecCheck.startupItems(dirs: [d])
        let r = SecCheck.startupItem(now: now, base: base)
        #expect(r.level == .bad && r.detail.contains("ai.okle42.sigtest"))
        #expect(SecFixer.fix(for: r)?.kind == .acceptStartup)
        try FileManager.default.removeItem(atPath: d + "/ai.okle42.sigtest.plist")
        #expect(SecCheck.startupItem(now: SecCheck.startupItems(dirs: [d]), base: base).level == .ok)
    }

    @Test("權限：讀不到資料庫只列 Orbit42 自己的、附給權限的按鈕；多了授權紅燈")
    func permissions() {
        let none = SecCheck.permissionsItem(now: nil, base: nil, own: ["輔助使用"])
        #expect(none.level == .info && none.detail.contains("Orbit42 自己有：輔助使用"))
        #expect(SecFixer.fix(for: none)?.label == "給 Orbit42 讀取權限")
        let p = SecCheck.parsePermissions("kTCCServiceScreenCapture|com.example.rec\nkTCCServiceAccessibility|com.example.ax\nkTCCServiceCamera|x\n")
        #expect(p == ["螢幕錄影：com.example.rec", "輔助使用：com.example.ax"].sorted())
        #expect(SecCheck.permissionsItem(now: p, base: p, own: []).level == .ok)
        let more = SecCheck.permissionsItem(now: p + ["完全取用磁碟：com.evil"], base: p, own: [])
        #expect(more.level == .bad && more.detail.contains("com.evil"))
    }

    func report(_ items: [SecItem]) -> SecReport { SecReport(items: items, at: Date(), seconds: 1) }

    @Test("自動跑：第一次不通知；沒變化不通知；多了開機項目要通知；檢查中不算變化")
    func changes() {
        let a = report([SecItem(no: 1, title: "FV", level: .ok, detail: "已開"), SecCheck.startupItem(now: ["使用者/x"], base: ["使用者/x"])])
        #expect(SecCheck.changes(old: nil, new: a).isEmpty)
        let sig = SecCheck.signature(a)
        #expect(SecCheck.changes(old: sig, new: a).isEmpty)
        // 細節字（例如「幾分鐘前查的」）變了但燈號一樣：不通知
        let a2 = report([SecItem(no: 1, title: "FV", level: .ok, detail: "已開（剛剛）"), SecCheck.startupItem(now: ["使用者/x"], base: ["使用者/x"])])
        #expect(SecCheck.changes(old: sig, new: a2).isEmpty)
        let b = report([SecItem(no: 1, title: "FV", level: .ok, detail: "已開"), SecCheck.startupItem(now: ["使用者/x", "使用者/ai.okle42.sigtest"], base: ["使用者/x"])])
        let ch = SecCheck.changes(old: sig, new: b)
        #expect(ch.count == 1 && ch[0].contains("ai.okle42.sigtest"))
        // 同樣的紅燈再跑一次：不重複通知
        #expect(SecCheck.changes(old: SecCheck.signature(b), new: b).isEmpty)
        let p = report([SecItem(no: 1, title: "FV", level: .pending, detail: "")])
        #expect(SecCheck.changes(old: sig, new: p).isEmpty)
    }

    @Test("每週：沒跑過或超過 7 天才跑")
    func weekly() {
        let now = Date()
        #expect(SecCheck.weeklyDue(last: nil, now: now))
        #expect(!SecCheck.weeklyDue(last: now.addingTimeInterval(-6 * 86400), now: now))
        #expect(SecCheck.weeklyDue(last: now.addingTimeInterval(-7 * 86400), now: now))
    }
}
