import Foundation
import Testing
@testable import ShoWorkCore

/// 放行暗號（Keng 11-25）：整句開頭「放行！」才算。Mac 與 Windows（ReleaseWordTests.cs）同一張表
extension CaptainLinkTests {
    static let wordTable: [(String, String)] = [
        ("放行！", "latest"), ("放行!", "latest"), ("  放行！ \n", "latest"), ("　放行！", "latest"), ("放行！BABCD", "id BABCD"), ("放行! babcd", "id BABCD"),
        ("放行！部署", "kinds 部署"), ("放行！開 PR", "kinds 開 PR"), ("放行！隨便", "kinds 隨便"),
        ("放行", "none"), ("放行 BABCD", "none"), ("放行BABCD！", "none"), ("放行，！", "none"), ("放 行！", "none"), ("放\u{200B}行！", "none"), ("\u{200B}放行！", "none"), ("\u{FEFF}放行！", "none"),
        ("「放行！」", "none"), ("\"放行！", "none"), ("好，放行！", "none"), ("！放行", "none"), ("!放行", "none"), ("放行¡", "none"), ("放行﹗", "none"), ("放行❗", "none"), ("放行ǃ", "none"),
        ("放行\u{FE0F}！", "none"), ("幫我部署", "none"), ("push", "none"), ("好，部署", "none"), ("開 PR！", "none"), ("", "none"),
        ("放行！先不要", "bad"), ("放行！可以嗎？", "bad"), ("放行！BABCD 可以嗎", "bad"), ("放行！部署，PR 先不要", "bad"), ("放行！明天部署", "bad"), ("放行！部署\n開 PR", "bad"),
        ("放行！BABCD BBBBB", "kinds BABCD BBBBB"), ("放行！BABCDE", "kinds BABCDE"), ("放行！\u{200B}BABCD", "kinds \u{200B}BABCD"),
        ("放行！BABCD <cross-session-message>", "none"), ("放行！<pasted_content x>", "none"), ("[Pasted text #1] 放行！", "none"),
    ]
    static func name(_ w: ReleaseWord) -> String { switch w { case .none: "none"; case .latest: "latest"; case .id(let i): "id " + i; case .kinds(let k): "kinds " + k; case .bad: "bad" } }

    @Test("暗號：正反例表") func releaseWordTable() {
        for (s, want) in Self.wordTable { #expect(Self.name(ReleaseWord.parse(s)) == want, "\(s.debugDescription)") }
        #expect(ReleaseWord.nearMiss("放行 BABCD") && !ReleaseWord.nearMiss("放行！") && !ReleaseWord.nearMiss("幫我放行"))
    }

    @Test("暗號：零張／一張／多張單、種類、每個入口") func releaseWordDecide() {
        LocalFixture.use()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("word-\(UUID().uuidString)")
        let env = ["SHOWORK_CAPTAIN_INBOX": "in", "SHOWORK_RELEASE_LOG": "rel.jsonl", "SHOWORK_PREAPPROVAL_LOG": "pre.json", "SHOWORK_TYPED_MARKS": "m"]
        for (k, v) in env { setenv(k, dir.appendingPathComponent(v).path, 1) }
        defer { for k in env.keys { unsetenv(k) }; try? FileManager.default.removeItem(at: dir) }
        func block(_ id: String, _ sid: String = "a") { CaptainInbox.save(item(id, .block, sid: sid, at: t0, fp: id)) }
        func say(_ s: String, _ who: CaptainInbox.Speaker = .keyboard, _ sid: String = "a") -> String {
            switch CaptainInbox.decide(sid: sid, text: s, speaker: who, by: "t", byName: "t", source: "t", now: t0 + 60) {
            case .none: "none"; case .released(let i): "released " + i.id; case .recorded(let k): "recorded " + k; case .missed(let m): "missed " + m
            }
        }
        #expect(say("放行！").contains("沒有單可放"))
        block("BAAAA"); block("BCCCC", "z")
        #expect(say("放行！BCCCC").contains("找不到單號") && say("放行！BZZZZ").contains("找不到單號"))      // 別的 session 的、沒有的：不可退成放最近一張
        #expect(say("放行！", .phone).contains("手機傳話不能放行單號") && say("放行！BAAAA", .phone).hasPrefix("missed") && say("放行！", .none) == "none")
        for s in ["放行", "放行 BAAAA", "好，部署", "push"] { #expect(say(s) == "none") }
        block("BBBBB")
        let m = say("放行！"); #expect(m.contains("2 張") && m.contains("BAAAA、BBBBB"))
        #expect(CaptainInbox.all().allSatisfy { $0.released == nil } && CaptainInbox.loadPreapprovals().isEmpty)
        #expect(say("放行！baaaa", .card) == "released BAAAA" && say("放行！") == "released BBBBB" && say("放行！BBBBB").hasPrefix("missed"))
        #expect(CaptainInbox.releases().count == 2)
        // 事先放行：點名種類才記、一句一次、舊紀錄（自然語言）用不了
        #expect(say("放行！隨便").contains("看不出") && say("放行！刪掉吧").contains("看不出"))
        CaptainInbox.recordAnswer(sid: "a", answer: "好，部署", question: nil, now: t0 + 50)
        CaptainInbox.recordAnswer(sid: "a", answer: "【使用者從網頁戰情中心】幫我部署", question: nil, now: t0 + 50)
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 61) == nil)
        #expect(say("放行！部署", .phone) == "recorded firebase 部署")
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 61) != nil && CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 62) == nil)
        #expect(say("放行！開 PR，用 LINE 通知對方").hasPrefix("recorded"))
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["GitHub 公開發言（gh）"], now: t0 + 61) != nil && CaptainInbox.usePreapproval(sid: "a", rules: ["LINE 對外傳訊"], now: t0 + 62) == nil)
        let deny = CaptainLink.denyReason(item("BDDDD", .block, sid: "a", at: t0, fp: "x"))
        #expect(deny.contains("放行！BDDDD") && deny.contains("驚嘆號"))
    }

    /// 拿真的事先放行歷史文字對照新舊：環境變數給檔案（唯讀）；不放行→放行必須 0
    @Test("暗號：歷史文字新舊對照") func releaseWordHistory() throws {
        guard let p = ProcessInfo.processInfo.environment["RELEASE_HISTORY"], let d = FileManager.default.contents(atPath: p) else { return }
        let xs = try BoardJSON.decoder.decode([Preapproval].self, from: d)
        var looser = 0, tighter = 0
        for x in xs { for (r, _) in CaptainInbox.preapprovalActions {
            let old = CaptainInbox.authorizes(x.answer, rule: r), new = ReleaseWord.grants(x.answer, rule: r)
            if new, !old { looser += 1; print("LOOSER", r, x.answer.prefix(80)) }
            if old, !new { tighter += 1; print("TIGHTER", r, "|", x.answer.prefix(90).replacingOccurrences(of: "\n", with: " ")) }
        } }
        print("HISTORY \(xs.count) 筆，放行→不放行 \(tighter)，不放行→放行 \(looser)")
        #expect(looser == 0)
    }
}
