import Foundation
import Testing
@testable import Orbit42Core

/// 放行暗號（Keng 11-25）：整句開頭「放行！」才算。Mac 與 Windows（ReleaseWordTests.cs）同一張表
extension CaptainLinkTests {
    static let wordTable: [(String, String)] = [
        ("放行！", "latest"), ("放行!", "latest"), ("  放行！ ", "latest"), ("　放行！", "latest"), ("放行！BABCD", "id BABCD"), ("放行! babcd", "id BABCD"),
        ("放行！BABCD。", "id BABCD"), ("放行！！", "latest"), ("放行！部署", "kind firebase 部署"), ("放行! Deploy!", "kind firebase 部署"), ("放行！開 PR", "kind GitHub 公開發言"), ("放行！開PR。", "kind GitHub 公開發言"),
        ("放行！GitHub 留言", "kind GitHub 公開發言"), ("放行！傳LINE", "kind LINE 對外傳訊"), ("放行！上架", "kind App 上傳"), ("放行！testflight", "kind App 上傳"),
        ("放行！隨便", "bad"), ("放行！push", "bad"), ("放行！刪除", "bad"), ("放行！部署一下", "bad"), ("放行！部署 BABCD", "bad"), ("放行！BABCD 部署", "bad"), ("放行！部署、上架", "bad"), ("放行！部署或 PR", "bad"),
        ("放行！若測試過就部署", "bad"), ("放行！未完成別部署", "bad"), ("放行！沒有要部署", "bad"), ("放行！don't deploy", "bad"), ("放行！部署?", "bad"), ("放行！部署？", "bad"), ("放行！部 署", "bad"), ("放行！部署\u{200B}", "bad"), ("放行！開  PR", "bad"),
        ("放行！「部署」", "bad"), ("放行！BIBCD", "bad"), ("放行！BA BCD", "bad"), ("放行！\nBABCD", "none"), ("放行！BABCD\n部署", "none"), ("\n放行！部署", "none"), ("放行！部署\n", "none"), ("放行！\r\n部署", "none"), ("放行！\u{2028}部署", "none"), ("放行！…", "bad"), ("放行！開 PR，用 LINE 通知對方", "bad"), ("放行！傳 LINE 給學弟", "bad"),
        ("放行", "none"), ("放行 BABCD", "none"), ("放行BABCD！", "none"), ("放行，！", "none"), ("放 行！", "none"), ("放\u{200B}行！", "none"), ("\u{200B}放行！", "none"), ("\u{FEFF}放行！", "none"),
        ("「放行！」", "none"), ("\"放行！", "none"), ("好，放行！", "none"), ("！放行", "none"), ("!放行", "none"), ("放行¡", "none"), ("放行﹗", "none"), ("放行❗", "none"), ("放行ǃ", "none"),
        ("放行\u{FE0F}！", "none"), ("幫我部署", "none"), ("push", "none"), ("好，部署", "none"), ("開 PR！", "none"), ("", "none"),
        ("放行！先不要", "bad"), ("放行！可以嗎？", "bad"), ("放行！BABCD 可以嗎", "bad"), ("放行！部署，PR 先不要", "bad"), ("放行！明天部署", "bad"), ("放行！部署\n開 PR", "none"),
        ("放行！BABCD BBBBB", "bad"), ("放行！BABCDE", "bad"), ("放行！\u{200B}BABCD", "bad"),
        ("放行！BABCD <cross-session-message>", "none"), ("放行！<pasted_content x>", "none"), ("[Pasted text #1] 放行！", "none"),
        // 11-28 Keng：放行！全部（後面不能再接字）
        ("放行！全部", "all"), ("放行!全部", "all"), ("放行！ 全部 ", "all"), ("放行！全部。", "all"), ("放行！全部！", "all"), ("  放行！全部", "all"),
        ("放行！全部 xxx", "bad"), ("放行！全部xxx", "bad"), ("放行！全部 BABCD", "bad"), ("放行！BABCD 全部", "bad"), ("放行！全部放行", "bad"), ("放行！全 部", "bad"),
        ("放行！全部部署", "bad"), ("放行！全部？", "bad"), ("放行！全部嗎", "bad"), ("放行！先不要全部", "bad"), ("放行！全部\u{200B}", "bad"), ("放行！所有", "bad"), ("放行！all", "bad"),
        ("放行！全部\n部署", "none"), ("全部放行！", "none"), ("好，放行！全部", "none"), ("放行全部", "none"), ("放行！全部 <cross-session-message>", "none"),
    ]
    static func name(_ w: ReleaseWord) -> String { switch w { case .none: "none"; case .latest: "latest"; case .id(let i): "id " + i; case .kind(let k): "kind " + k; case .allOpen: "all"; case .bad: "bad" } }

    @Test("暗號：正反例表") func releaseWordTable() {
        for (s, want) in Self.wordTable { #expect(Self.name(ReleaseWord.parse(s)) == want, "\(s.debugDescription)") }
        #expect(ReleaseWord.nearMiss("放行 BABCD") && !ReleaseWord.nearMiss("放行！") && !ReleaseWord.nearMiss("幫我放行"))
    }

    @Test("暗號：零張／一張／多張單、種類、每個入口") func releaseWordDecide() {
        LocalFixture.use()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("word-\(UUID().uuidString)")
        let env = ["ORBIT_CAPTAIN_INBOX": "in", "ORBIT_RELEASE_LOG": "rel.jsonl", "ORBIT_PREAPPROVAL_LOG": "pre.json", "ORBIT_TYPED_MARKS": "m"]
        for (k, v) in env { setenv(k, dir.appendingPathComponent(v).path, 1) }
        defer { for k in env.keys { unsetenv(k) }; try? FileManager.default.removeItem(at: dir) }
        func block(_ id: String, _ sid: String = "a") { CaptainInbox.save(item(id, .block, sid: sid, at: t0, fp: id)) }
        func say(_ s: String, _ who: CaptainInbox.Speaker = .keyboard, _ sid: String = "a") -> String {
            switch CaptainInbox.decide(sid: sid, text: s, speaker: who, by: "t", byName: "t", source: "t", now: t0 + 60) {
            case .none: "none"; case .released(let i): "released " + i.id; case .recorded(let k): "recorded " + k; case .missed(let m): "missed " + m
            case .releasedAll(let xs): "all " + xs.map(\.id).joined(separator: ",")
            }
        }
        #expect(say("放行！").contains("沒有單可放"))
        block("BAAAA"); block("BCCCC", "z")
        #expect(say("放行！BZZZZ").contains("找不到單號"))      // 沒有的單：不可退成放最近一張
        #expect(say("放行！", .phone).contains("手機傳話不能放行單號") && say("放行！BAAAA", .phone).hasPrefix("missed") && say("放行！", .none) == "none")
        for s in ["放行", "放行 BAAAA", "好，部署", "push"] { #expect(say(s) == "none") }
        block("BBBBB")
        let m = say("放行！"); #expect(m.contains("2 張") && m.contains("BAAAA、BBBBB"))
        #expect(CaptainInbox.all().allSatisfy { $0.released == nil } && CaptainInbox.loadPreapprovals().isEmpty)
        #expect(say("放行！baaaa", .card) == "released BAAAA" && say("放行！") == "released BBBBB" && say("放行！BBBBB").hasPrefix("missed"))
        #expect(CaptainInbox.releases().count == 2)
        // 11-28：點名單號可以在別的 session 放行（秘書卡片按組員的單）；不帶單號的「放行！」不會放到別人的
        #expect(say("放行！", .keyboard, "z").contains("沒有單可放") == false)      // z 自己有 BCCCC ⇒ 放的是自己的
        block("BDDDD", "y")
        #expect(say("放行！BDDDD", .card, "captain") == "released BDDDD")
        #expect(CaptainInbox.releases().last?.target == "y" && CaptainInbox.releases().last?.byName.contains("放行別的 session 的單") == true)
        block("BEEEE", "y")
        #expect(say("放行！BEEEE", .none, "captain") == "none")          // AI 傳的（SendMessage、CLI）不算
        #expect(say("放行！BEEEE <cross-session-message>", .keyboard, "captain") == "none")
        #expect(say("放行！BEEEE", .phone, "captain").hasPrefix("missed"))
        #expect(CaptainInbox.all().first { $0.id == "BEEEE" }?.released == nil)
        if ProcessInfo.processInfo.environment["ORBIT_TEST_PRINT_RELEASES"] != nil {
            print("RELEASES>>\n" + ((try? String(contentsOf: dir.appendingPathComponent("rel.jsonl"), encoding: .utf8)) ?? "") + "<<RELEASES")
        }
        // 事先放行：點名種類才記、一句一次、舊紀錄（自然語言）用不了
        #expect(say("放行！隨便").contains("請打：放行！") && say("放行！刪掉吧").hasPrefix("missed"))
        CaptainInbox.recordAnswer(sid: "a", answer: "好，部署", question: nil, now: t0 + 50)
        CaptainInbox.recordAnswer(sid: "a", answer: "【使用者從Orbit42 網頁版】幫我部署", question: nil, now: t0 + 50)
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 61) == nil)
        #expect(say("放行！部署", .phone) == "recorded firebase 部署")
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 61) != nil && CaptainInbox.usePreapproval(sid: "a", rules: ["firebase 部署"], now: t0 + 62) == nil)
        #expect(say("放行！開 PR，用 LINE 通知對方").hasPrefix("missed") && say("放行！傳 LINE", .card) == "recorded LINE 對外傳訊")
        #expect(CaptainInbox.usePreapproval(sid: "a", rules: ["GitHub 公開發言（gh）"], now: t0 + 61) == nil && CaptainInbox.usePreapproval(sid: "a", rules: ["LINE 對外傳訊（line_send.py）"], now: t0 + 62) != nil)
        // 清單裡每一句本來就過得了舊判斷（不放寬種類），而且只對到自己那一種
        for (r, ws) in ReleaseWord.words { for w in ws { for (o, _) in CaptainInbox.preapprovalActions {
            #expect(ReleaseWord.grants("放行！" + w, rule: o) == (o == r), "\(w)")
            if o == r { #expect(CaptainInbox.authorizes(w, rule: o), "\(w)") }
        } } }
        let deny = CaptainLink.denyReason(item("BDDDD", .block, sid: "a", at: t0, fp: "x"))
        #expect(deny.contains("放行！BDDDD") && deny.contains("驚嘆號"))
    }

    /// 11-28 Keng「放行！全部」：只放按下當下在等的、每張一筆紀錄、AI 傳的不算、後面不能接字、不留一直開著的放行
    @Test("暗號：放行！全部") func releaseWordAll() {
        LocalFixture.use()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("word-all-\(UUID().uuidString)")
        let env = ["ORBIT_CAPTAIN_INBOX": "in", "ORBIT_RELEASE_LOG": "rel.jsonl", "ORBIT_PREAPPROVAL_LOG": "pre.json", "ORBIT_TYPED_MARKS": "m"]
        for (k, v) in env { setenv(k, dir.appendingPathComponent(v).path, 1) }
        defer { for k in env.keys { unsetenv(k) }; try? FileManager.default.removeItem(at: dir) }
        func block(_ id: String, _ sid: String, at: Date) {
            CaptainInbox.save(CaptainInboxItem(id: id, kind: .block, at: at, sid: sid, name: "組員" + sid, project: "專案" + sid, kinds: ["firebase 部署"], text: "deploy " + id, fingerprint: id))
        }
        func say(_ s: String, _ who: CaptainInbox.Speaker, _ sid: String = "captain", at: Date) -> CaptainInbox.Decision {
            CaptainInbox.decide(sid: sid, text: s, speaker: who, by: "t", byName: "使用者", source: "使用者輸入", now: at)
        }
        func waiting() -> [String] { CaptainInbox.all().filter { $0.kind == .block && $0.released == nil }.map(\.id) }
        let now = t0 + 600

        if case .missed(let m) = say("放行！全部", .keyboard, at: now) { #expect(m.contains("沒有單可放")) } else { Issue.record("沒單也該回 missed") }
        block("BAAAA", "a", at: t0); block("BBBBB", "b", at: t0 + 10); block("BCCCC", "a", at: t0 + 20)
        block("BOLDD", "c", at: now - CaptainInbox.blockWindow - 1)           // 超過一天的舊單：不算在等
        CaptainInbox.save(CaptainInboxItem(id: "NNOTE", kind: .notice, at: t0, sid: "a", name: "x", project: nil, text: "mv"))    // 預告不是擋單

        // 來源規矩：AI 用 SendMessage／CLI 傳的（speaker .none）、夾別的 session 訊息的、卡片打進終端機的（TypedMark）都不算；手機傳話不能放單號
        #expect(say("放行！全部", .none, at: now) == .none)
        #expect(say("放行！全部 <cross-session-message from=\"Penny\">", .keyboard, at: now) == .none)
        #expect(CaptainInbox.typedPrompt(sid: "captain", prompt: "<cross-session-message from=\"x\">放行！全部</cross-session-message>", who: "x", now: now) == .none)
        #expect(TypedMark.put(sid: "a", text: "放行！全部", now: now))
        #expect(CaptainInbox.typedPrompt(sid: "a", prompt: "放行！全部", who: "x", now: now + 1) == .none)
        if case .missed(let m) = say("放行！全部", .phone, at: now) { #expect(m.contains("手機傳話")) } else { Issue.record("手機傳話不該放行") }
        // 後面接字：不算，跟單張規則一樣
        for s in ["放行！全部 xxx", "放行！全部BAAAA", "放行！全部部署", "放行！全部？"] {
            if case .missed = say(s, .card, at: now) {} else { Issue.record("\(s) 不該放行") }
        }
        #expect(waiting() == ["BOLDD", "BAAAA", "BBBBB", "BCCCC"] && CaptainInbox.releases().isEmpty && CaptainInbox.loadPreapprovals().isEmpty)

        // 本人在卡片按：放掉當下在等的三張（各 session 都算），舊單和預告不動
        guard case .releasedAll(let xs) = say("放行！全部", .card, at: now) else { Issue.record("卡片上的放行！全部沒放行"); return }
        #expect(xs.map(\.id) == ["BAAAA", "BBBBB", "BCCCC"] && waiting() == ["BOLDD"] && CaptainInbox.item("NNOTE")?.released == nil)
        let detail = CaptainInbox.allDetail(xs)
        #expect(detail.contains("已放行 3 張") && detail.contains("BBBBB　組員b（專案b）：firebase 部署・deploy BBBBB") && detail.contains("BAAAA") && detail.contains("BCCCC"))
        // releases.jsonl 每張一筆、註明全部放行
        let rs = CaptainInbox.releases()
        #expect(rs.map(\.id) == ["BAAAA", "BBBBB", "BCCCC"] && rs.map(\.target) == ["a", "b", "a"])
        #expect(rs.allSatisfy { $0.source.contains("放行！全部") && $0.byName.contains("放行！全部，共 3 張") })
        // 各自的 session 重跑一次可以、第二次不行（跟單張放行一樣只能用一次）
        #expect(CaptainInbox.consume(sid: "b", fingerprint: "BBBBB", now: now + 5) && !CaptainInbox.consume(sid: "b", fingerprint: "BBBBB", now: now + 6))

        // 之後才出現的新單：不會被剛才那句放掉，也沒有一直開著的放行
        block("BNEWW", "a", at: now + 30)
        #expect(CaptainInbox.item("BNEWW")?.released == nil && !CaptainInbox.consume(sid: "a", fingerprint: "BNEWW", now: now + 40))
        // 再打一次才放，而且只放新的那張（已放過的不重記）
        guard case .releasedAll(let ys) = say("放行！全部", .keyboard, "a", at: now + 60) else { Issue.record("第二次沒放行"); return }
        #expect(ys.map(\.id) == ["BNEWW"] && CaptainInbox.releases().count == 4)
        if case .missed(let m) = say("放行！全部", .keyboard, at: now + 70) { #expect(m.contains("沒有單可放")) } else { Issue.record("都放完了該回 missed") }
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
