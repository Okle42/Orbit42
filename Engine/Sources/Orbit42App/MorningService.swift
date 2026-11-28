import AppKit
import EventKit
import Foundation
import Orbit42Core

/// 11-28 OpenJarvis 升級 A 組（Keng：「除了換更好聽的付費聲音，其他都先做起來」）。
/// ① 語音晨報：每分鐘看一次——到了設定時間（預設 08:30）、今天還沒念、人在 Mac 前（2 分鐘內碰過鍵盤滑鼠）⇒
///    先把行事曆／iMessage／Gmail 抓進本機索引，再組稿（AI 口語稿，失敗用規則稿），交給球體一句一句念（球體選的聲音、字幕同步）
/// ② 個人資料搜尋：球體上說「找／搜尋 …」或按搜尋鈕 ⇒ 查本機索引，結果附出處
/// 個人資料只讀、只存本機（Application Support/Orbit42/personal/），交給 claude 改口語時只送條列事實，不送信的內文。
@MainActor
final class MorningService {
    static let shared = MorningService()
    /// 晨報稿好了：每顆球自己決定出不出聲（兩顆都開時只有桌面版出聲，網頁既有規則）
    static let ready = Notification.Name("orbit.morning.ready")

    private let defaults = UserDefaults(suiteName: AppPrefs.suite)
    private var timer: Timer?
    private(set) var busy = false
    private(set) var last: [String: Any]?

    func start() {
        guard timer == nil, !AppTest.mode else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { MorningService.shared.tick() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.tick() }
    }

    /// 多久沒碰鍵盤滑鼠（秒）
    static var idle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var lastSaid: Date? {
        get { defaults?.object(forKey: "morning.lastSaid") as? Date }
        set { defaults?.set(newValue, forKey: "morning.lastSaid") }
    }

    private func tick() {
        guard !busy, MorningBrief.due(MorningBrief.settings(), now: Date(), lastSaid: lastSaid, idle: Self.idle) else { return }
        lastSaid = Date()          // 先記：抓資料要一兩分鐘，期間不要再觸發
        run(auto: true)
    }

    /// 按「晨報」：馬上重抓重念（auto＝排程自動念）
    func run(auto: Bool) {
        guard !busy else { return }
        busy = true
        Task.detached(priority: .utility) {
            await Self.syncCalendar()
            Self.syncLocal()
            Self.syncMail()
            let o = Self.compose()
            await MainActor.run {
                var p = o; p["auto"] = auto
                MorningService.shared.last = p
                MorningService.shared.busy = false
                NotificationCenter.default.post(name: Self.ready, object: nil, userInfo: p)
            }
        }
    }

    // MARK: 組稿

    nonisolated static func compose(now: Date = Date()) -> [String: Any] {
        let ix = try? PersonalIndex()
        let f = MorningBrief.gather(index: ix, asks: AskQueue.all(), names: NicknameStore.all().mapValues(\.name), now: now)
        let draft = MorningBrief.draft(f)
        var text = draft, ai = false
        if let bin = Tools.claude() {
            let r = Tools.run(bin, MorningBrief.claudeArgs, cwd: NSTemporaryDirectory(), stdin: MorningBrief.factSheet(f), timeout: 45, qos: .utility)
            if r.code == 0, let t = MorningBrief.tidy(r.out) { text = t; ai = true }
        }
        // 留一份稿子在本機（Keng 要聽／對照用）
        let dir = Paths.supportDir.appendingPathComponent("personal/morning", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        try? (text + "\n\n---\n" + MorningBrief.factSheet(f)).write(to: dir.appendingPathComponent(df.string(from: now) + ".txt"), atomically: true, encoding: .utf8)
        return ["text": text, "lines": MorningBrief.sentences(text), "ai": ai, "id": Int(now.timeIntervalSince1970)]
    }

    // MARK: 抓資料（一個接一個跑，16GB 不並行）

    /// Mac 行事曆（EventKit）：昨天到 14 天後。第一次會跳系統的行事曆權限對話框
    nonisolated static func syncCalendar() async {
        let store = EKEventStore()
        let ok: Bool
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { ok = true }
        else { ok = (try? await store.requestFullAccessToEvents()) ?? false }
        guard ok else { return }
        let now = Date(), cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!, to = cal.date(byAdding: .day, value: 14, to: now)!
        let evs = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        let docs = evs.map { e in
            PersonalDoc(source: .calendar, ref: (e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString) + "@" + String(Int(e.startDate.timeIntervalSince1970)),
                        title: e.title ?? "（沒有標題）",
                        body: [e.location, e.notes, (e.attendees ?? []).compactMap(\.name).joined(separator: "、")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                        who: e.organizer?.name ?? e.calendar.title, at: e.startDate, end: e.endDate, link: e.url?.absoluteString)
        }
        _ = try? PersonalIndex().upsert(docs)
    }

    /// iMessage（唯讀 chat.db；沒有完全磁碟取用就略過）
    nonisolated static func syncLocal() {
        if let d = try? IMessageReader.read(days: 30) { _ = try? PersonalIndex().upsert(d) }
    }

    /// Gmail（Claude 已連好的連接器，唯讀工具）：晨報前抓近 2 天；Drive 留給 `orbit search sync drive`（比較久）
    nonisolated static func syncMail(days: Int = 2) {
        guard let bin = Tools.claude() else { return }
        let r = Tools.run(bin, ConnectorSync.claudeArgs(.mail), cwd: NSTemporaryDirectory(), stdin: ConnectorSync.prompt(.mail, days: days), timeout: 150, qos: .utility)
        guard r.code == 0 else { return }
        let docs = ConnectorSync.parse(r.out, kind: .mail)
        if !docs.isEmpty { _ = try? PersonalIndex().upsert(docs) }
    }

    // MARK: 搜尋

    nonisolated static func search(_ q: String) -> [String: Any] {
        guard let ix = try? PersonalIndex() else { return ["q": q, "hits": [], "error": "索引打不開"] }
        let empty = ((try? ix.stats()) ?? []).allSatisfy { $0.1 == 0 }
        let hits = (try? ix.search(q, limit: 6)) ?? []
        return ["q": q, "empty": empty, "keywords": PersonalIndex.keywords(q),
                "hits": hits.map { ["cite": $0.cite, "snippet": $0.snippet, "link": $0.doc.link ?? "", "source": $0.doc.source.zh, "title": $0.doc.title] }]
    }
}
