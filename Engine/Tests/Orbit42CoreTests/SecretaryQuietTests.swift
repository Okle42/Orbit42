import Foundation
import Testing
@testable import Orbit42Core

/// 11-26 秘書 4 點省用量（第一階段 C）
@Suite("秘書省用量（11-26）")
struct SecretaryQuietTests {
    func defaults() throws -> (UserDefaults, String) {
        let name = "orbit.test.secretary.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("巡檢預設 120 分鐘；設了照設定；0＝關")
    func alarmDefault() throws {
        let (d, n) = try defaults(); defer { d.removePersistentDomain(forName: n) }
        #expect(CaptainLink.alarmDefaultMinutes == 120)
        #expect(CaptainLink.alarmMinutes(d) == 120)
        #expect(CaptainLink.alarmMinutes(nil) == 120)
        d.set(45, forKey: CaptainLink.alarmKey); #expect(CaptainLink.alarmMinutes(d) == 45)
        d.set(0, forKey: CaptainLink.alarmKey); #expect(CaptainLink.alarmMinutes(d) == 0)
    }

    @Test("秘書換哨門檻預設 300k")
    func shiftDefault() throws {
        let (d, n) = try defaults(); defer { d.removePersistentDomain(forName: n) }
        #expect(CaptainLink.captainCtxDefault == 300_000)
        #expect(CaptainLink.captainCtxLimit(d) == 300_000)
        d.set(0, forKey: CaptainLink.captainCtxKey); #expect(CaptainLink.captainCtxLimit(d) == 300_000)
    }

    @Test("轉送只叫醒秘書做要決定的事：純狀態卡（待審、卡住、完成、工作中）不轉，帶 --ask 才轉")
    func relayOnlyAsks() {
        for s in [SelfReport.Status.review, .blocked, .done, .working] {
            #expect(!CardRelay.needsCaptain(SelfReport(status: s, summary: "x"), policy: .quiet), "\(s)")
        }
        #expect(CardRelay.needsCaptain(SelfReport(status: .review, summary: "x", ask: "要 push 嗎？"), policy: .quiet))
        #expect(CardRelay.needsCaptain(SelfReport(status: .blocked, ask: "等哪個？"), policy: .quiet))
        #expect(CardRelay.needsCaptain(SelfReport(status: .done), policy: .legacy), "舊行為開關照舊")
    }

    @Test("重複內容不轉：同一張帶題的卡第二次不送")
    func relayNoRepeat() {
        var st = CardRelay.State()
        let now = Date()
        let r = SelfReport(status: .review, summary: "x", ask: "要 push 嗎？", options: ["好", "不要"], at: now)
        _ = CardRelay.plan(reports: [:], captain: "CAP", captainLive: true, state: &st, now: now) { _, _ in "t" }       // 種子
        let a = CardRelay.plan(reports: ["S": r], captain: "CAP", captainLive: true, state: &st, now: now) { _, _ in "t" }
        let b = CardRelay.plan(reports: ["S": r], captain: "CAP", captainLive: true, state: &st, now: now + 120) { _, _ in "t" }
        #expect(a.count == 1); #expect(b.isEmpty)
        let status = SelfReport(status: .blocked, summary: "等背景工作", at: now + 200)
        #expect(CardRelay.plan(reports: ["T": status], captain: "CAP", captainLive: true, state: &st, now: now + 200) { _, _ in "t" }.isEmpty)
    }

    @Test("秘書守則與開場說明：等待的回合不用發卡、巡檢 120 分鐘、門檻 300k、已答不另外傳訊")
    func manualText() {
        let m = Captain.manual(orbit: "orbit")
        #expect(m.contains("每 120 分鐘")); #expect(m.contains("預設 300k")); #expect(m.contains("不用發卡片"))
        #expect(!m.contains("會傳「【使用者已答】"))
        #expect(CardRules.brief(orbit: "orbit").contains("整張卡都不用發"))
    }
}
