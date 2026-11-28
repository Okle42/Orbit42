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
            case .releasedAll(let xs, let ask): "all " + xs.map(\.id).joined(separator: ",") + (ask.isEmpty ? "" : " ask")
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
    static let rmKind = ["rm 刪除（暫存區以外）"]
    func allEnv(_ tag: String) -> URL {
        LocalFixture.use()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)")
        for (k, v) in ["ORBIT_CAPTAIN_INBOX": "in", "ORBIT_RELEASE_LOG": "rel.jsonl", "ORBIT_PREAPPROVAL_LOG": "pre.json", "ORBIT_TYPED_MARKS": "m"] {
            setenv(k, dir.appendingPathComponent(v).path, 1)
        }
        return dir
    }
    func allEnvDone(_ dir: URL) {
        for k in ["ORBIT_CAPTAIN_INBOX", "ORBIT_RELEASE_LOG", "ORBIT_PREAPPROVAL_LOG", "ORBIT_TYPED_MARKS"] { unsetenv(k) }
        try? FileManager.default.removeItem(at: dir)
    }
    func blockAt(_ id: String, _ sid: String, at: Date, kinds: [String] = rmKind, text: String? = nil) {
        CaptainInbox.save(CaptainInboxItem(id: id, kind: .block, at: at, sid: sid, name: "組員" + sid, project: "專案" + sid, kinds: kinds, text: text ?? "rm -rf " + id, fingerprint: id))
    }
    func waitingIds() -> [String] { CaptainInbox.all().filter { $0.kind == .block && $0.released == nil }.map(\.id) }
    /// 待答題資料夾用 TaskLocal（AskQueueTests 在別的 suite 平行跑，會改 ORBIT_ASKS_DIR）
    func withAllEnv(_ tag: String, _ body: (URL) -> Void) {
        let dir = allEnv(tag); defer { allEnvDone(dir) }
        AskQueue.$testDir.withValue(dir.appendingPathComponent("asks", isDirectory: true)) { body(dir) }
    }
    @Test("暗號：放行！全部") func releaseWordAll() { withAllEnv("word-all", releaseWordAllBody) }
    @Test("放行！全部：對外單改勾選卡確認") func releasePickCard() { withAllEnv("word-pick", releasePickCardBody) }

    func releaseWordAllBody(_ dir: URL) {
        func say(_ s: String, _ who: CaptainInbox.Speaker, _ sid: String = "captain", at: Date) -> CaptainInbox.Decision {
            CaptainInbox.decide(sid: sid, text: s, speaker: who, by: "t", byName: "使用者", source: "使用者輸入", now: at)
        }
        let now = t0 + 600

        if case .missed(let m) = say("放行！全部", .keyboard, at: now) { #expect(m.contains("沒有單可放")) } else { Issue.record("沒單也該回 missed") }
        blockAt("BAAAA", "a", at: t0); blockAt("BBBBB", "b", at: t0 + 10); blockAt("BCCCC", "a", at: t0 + 20)
        blockAt("BOLDD", "c", at: now - CaptainInbox.blockWindow - 1)           // 超過一天的舊單：不算在等
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
        #expect(waitingIds() == ["BOLDD", "BAAAA", "BBBBB", "BCCCC"] && CaptainInbox.releases().isEmpty && CaptainInbox.loadPreapprovals().isEmpty && AskQueue.all().isEmpty)

        // 本人在卡片按：放掉當下在等的三張（各 session 都算），舊單和預告不動
        guard case .releasedAll(let xs, let asking) = say("放行！全部", .card, at: now) else { Issue.record("卡片上的放行！全部沒放行"); return }
        #expect(xs.map(\.id) == ["BAAAA", "BBBBB", "BCCCC"] && asking.isEmpty && waitingIds() == ["BOLDD"] && CaptainInbox.item("NNOTE")?.released == nil)
        let detail = CaptainInbox.allDetail(xs, asking: asking)
        #expect(detail.contains("已放行 3 張") && detail.contains("BBBBB　組員b（專案b）：rm 刪除（暫存區以外）・rm -rf BBBBB") && detail.contains("BAAAA") && detail.contains("BCCCC"))
        // releases.jsonl 每張一筆、註明全部放行
        let rs = CaptainInbox.releases()
        #expect(rs.map(\.id) == ["BAAAA", "BBBBB", "BCCCC"] && rs.map(\.target) == ["a", "b", "a"])
        #expect(rs.allSatisfy { $0.source.contains("放行！全部") && $0.byName.contains("放行！全部，共 3 張") })
        // 各自的 session 重跑一次可以、第二次不行（跟單張放行一樣只能用一次）
        #expect(CaptainInbox.consume(sid: "b", fingerprint: "BBBBB", now: now + 5) && !CaptainInbox.consume(sid: "b", fingerprint: "BBBBB", now: now + 6))

        // 之後才出現的新單：不會被剛才那句放掉，也沒有一直開著的放行
        blockAt("BNEWW", "a", at: now + 30)
        #expect(CaptainInbox.item("BNEWW")?.released == nil && !CaptainInbox.consume(sid: "a", fingerprint: "BNEWW", now: now + 40))
        // 再打一次才放，而且只放新的那張（已放過的不重記）
        guard case .releasedAll(let ys, _) = say("放行！全部", .keyboard, "a", at: now + 60) else { Issue.record("第二次沒放行"); return }
        #expect(ys.map(\.id) == ["BNEWW"] && CaptainInbox.releases().count == 4)
        if case .missed(let m) = say("放行！全部", .keyboard, at: now + 70) { #expect(m.contains("沒有單可放")) } else { Issue.record("都放完了該回 missed") }
    }

    /// 11-28 Keng：「放行！全部」碰到對外的（部署、LINE、GitHub⋯）改發多選答案卡，按選項只打勾、按確認才送、只放勾的
    func releasePickCardBody(_ dir: URL) {
        let now = t0 + 600
        blockAt("BLOCL", "a", at: t0)                                                                    // 只動本機：直接放
        blockAt("BDEP2", "a", at: t0 + 1, kinds: ["firebase 部署"], text: "firebase deploy --only hosting")
        blockAt("BLIN3", "b", at: t0 + 2, kinds: ["LINE 對外傳訊（line_send.py）"], text: "python3 line_send.py 通知學弟")
        blockAt("BGHP4", "b", at: t0 + 3, kinds: ["GitHub 公開發言（gh）"], text: "gh pr create")
        blockAt("BPSH5", "c", at: t0 + 4, kinds: ["push 掃到密鑰／客戶資料"], text: "Orbit42：客戶關鍵字")
        blockAt("BAPP6", "c", at: t0 + 5, kinds: ["App 上傳 App Store Connect"], text: "xcodebuild -exportArchive")
        blockAt("BOPQ7", "a", at: t0 + 6, kinds: ["包裝指令（看不出要跑什麼）"], text: "sh -c \"$X\"")      // 看不出要跑什麼：保守當對外
        #expect(!ReleasePick.isOutward(CaptainInbox.item("BLOCL")!) && ReleasePick.isOutward(CaptainInbox.item("BOPQ7")!))

        guard case .releasedAll(let xs, let asking) = CaptainInbox.decide(sid: "captain", text: "放行！全部", speaker: .card, by: "t", byName: "使用者", source: "使用者輸入", now: now)
        else { Issue.record("放行！全部沒動作"); return }
        #expect(xs.map(\.id) == ["BLOCL"] && asking.map(\.id) == ["BDEP2", "BLIN3", "BGHP4", "BPSH5", "BAPP6", "BOPQ7"])
        #expect(waitingIds() == ["BDEP2", "BLIN3", "BGHP4", "BPSH5", "BAPP6", "BOPQ7"])                    // 對外的一張都沒放
        #expect(CaptainInbox.allDetail(xs, asking: asking).contains("對外的 6 張先不放"))
        // 6 張 ⇒ 兩張卡（4＋2），每個選項：單號、誰、要做什麼、送去哪裡
        let qs = AskQueue.load("captain")
        #expect(qs.count == 2 && qs.allSatisfy { $0.pickOnly && $0.multi == true } && qs.map { $0.options?.count ?? 0 } == [4, 2])
        #expect(qs[0].picks == ["BDEP2", "BLIN3", "BGHP4", "BPSH5"] && qs[1].picks == ["BAPP6", "BOPQ7"])
        let o0 = qs[0].options![0]
        #expect(o0.hasPrefix("BDEP2　組員a（專案a）：firebase 部署，送到 Firebase 網站") && o0.contains("firebase deploy"))
        #expect(qs[0].options![1].contains("送到 LINE") && qs[0].options![2].contains("送到 GitHub") && qs[0].options![3].contains("送到 GitHub") && qs[1].options![0].contains("App Store Connect"))
        // 再打一次「放行！全部」：同一張單不重發
        _ = CaptainInbox.decide(sid: "captain", text: "放行！全部", speaker: .card, by: "t", byName: "使用者", source: "使用者輸入", now: now + 1)
        #expect(AskQueue.load("captain").count == 2)

        // 按選項不會送出：勾選題沒有「要送的字」，一般答案路（AskQueue.claim）拿不到
        let q = qs[0]
        for p in [AnswerPick(askId: q.id, option: q.options![0]), AnswerPick(askId: q.id, option: nil, free: "1、2"), AnswerPick(askId: q.id, option: "確認放行")] {
            #expect(p.text(for: q) == nil && AskQueue.claim(sid: "captain", pick: p, now: now) == .gone)
        }
        // 終端機打字不算答它、AI 照提醒 withdraw all 也收不掉
        #expect(AskQueue.answeredInTerminal(sid: "captain", prompt: "1 2 都放", cardsDir: dir, tasksDir: dir, now: now).isEmpty)
        #expect(AskQueue.leftoverNote(sid: "captain", prompt: "1 2 都放", orbit: "orbit", now: now) == nil)
        #expect(AskQueue.withdraw(sid: "captain", id: "all") == 0 && AskQueue.withdraw(sid: "captain", id: q.id) == 0 && AskQueue.load("captain").count == 2)

        func pick(_ id: String, _ chosen: [Int], _ who: CaptainInbox.Speaker = .card) -> ReleasePick.Outcome {
            ReleasePick.answer(sid: "captain", askId: id, chosen: chosen, speaker: who, by: "Orbit42", byName: "使用者（Orbit42答案卡）", source: "Orbit42回答", now: now + 10)
        }
        // AI 送來的勾選（SendMessage／CLI／打字 ⇒ speaker 不是 .card）不算：一張都不放、題目留著
        for who in [CaptainInbox.Speaker.none, .keyboard, .phone] {
            if case .rejected = pick(q.id, [0, 1, 2, 3], who) {} else { Issue.record("\(who) 的勾選不該算") }
        }
        // 勾選對不上：不送
        for bad in [[4], [0, 0], [-1]] { if case .rejected = pick(q.id, bad) {} else { Issue.record("\(bad) 不該送") } }
        #expect(waitingIds().count == 6 && CaptainInbox.releases().count == 1 && AskQueue.load("captain").count == 2)

        // 勾 2 張（部署、GitHub PR）按確認：只放那 2 張，每張一筆紀錄；沒勾的維持擋下
        guard case .done(let got, let kept) = pick(q.id, [2, 0]) else { Issue.record("確認放行沒送出"); return }
        #expect(got.map(\.id) == ["BDEP2", "BGHP4"] && kept == ["BLIN3", "BPSH5"])
        #expect(waitingIds() == ["BLIN3", "BPSH5", "BAPP6", "BOPQ7"])
        let rs = CaptainInbox.releases().suffix(2)
        #expect(rs.map(\.id) == ["BDEP2", "BGHP4"] && rs.allSatisfy { $0.source.contains("放行！全部（勾選）") && $0.byName.contains("勾選確認") })
        #expect(ReleasePick.summary(.done(released: got, kept: kept)).contains("沒勾、維持擋下：BLIN3、BPSH5"))
        // 同一張卡不能再送一次
        if case .rejected = pick(q.id, [1]) {} else { Issue.record("同一張卡不該送兩次") }
        #expect(CaptainInbox.item("BLIN3")?.released == nil)

        // 第二張卡按「全部不放」：一張都不放、卡收掉、單還擋著
        guard case .done(let none, let kept2) = pick(qs[1].id, []) else { Issue.record("全部不放沒送出"); return }
        #expect(none.isEmpty && kept2 == ["BAPP6", "BOPQ7"] && AskQueue.load("captain").isEmpty && CaptainInbox.releases().count == 3)

        // 網頁／手機 API：chosen 要是數字陣列、不重複、最多 4 個，不能同時帶選項字或打字
        func parse(_ o: [String: Any]) -> WebAction? { try? WebAction.parse(path: "/api/answer", body: JSONSerialization.data(withJSONObject: o)).get() }
        #expect(parse(["id": "a", "askId": "Q1", "chosen": [0, 2]]) == .answer(session: "a", text: "勾選確認放行：1、3", askId: "Q1", chosen: [0, 2]))
        #expect(parse(["id": "a", "askId": "Q1", "chosen": [Int]()]) == .answer(session: "a", text: "勾選確認放行：全部不放", askId: "Q1", chosen: []))
        for o: [String: Any] in [["id": "a", "askId": "Q1", "chosen": [0, 0]], ["id": "a", "askId": "Q1", "chosen": [9]], ["id": "a", "askId": "Q1", "chosen": "0"],
                                 ["id": "a", "askId": "Q1", "chosen": [true]], ["id": "a", "chosen": [0]], ["id": "a", "askId": "Q1", "chosen": [0], "option": "好"],
                                 ["id": "a", "askId": "Q1", "chosen": [0, 1, 2, 3, 4]]] {
            #expect(parse(o) == nil, "\(o)")
        }
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
