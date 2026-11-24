import AppIntents

/// 11-24 Keng：動作按鈕／控制中心／Siri 捷徑「Orbit42 開始說話」：打開 Orbit42 就開始聽，說完交給 Mac 上的智能體。
/// App 和控制中心擴充兩邊都編這個檔；真的開始聽在 App 裡（擴充沒有麥克風），用 UserDefaults 旗標＋通知交給 App。
struct ListenIntent: AppIntent {
    static let title: LocalizedStringResource = "Orbit42 開始說話"
    static let description = IntentDescription("打開 Orbit42 開始聽，說完交給 Mac 上的智能體。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ListenTrigger.fire()
        return .result()
    }
}

enum ListenTrigger {
    static let note = Notification.Name("Orbit42.listen")
    static let key = "orbit42.listenPending"
    static func fire() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
        NotificationCenter.default.post(name: note, object: nil)
    }
    /// App 回到前景時看一下：10 秒內有人按過就開始聽（只算一次）
    static func take() -> Bool {
        let t = UserDefaults.standard.double(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return t > 0 && Date().timeIntervalSince1970 - t < 10
    }
}
