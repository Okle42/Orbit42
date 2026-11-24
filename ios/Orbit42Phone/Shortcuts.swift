import AppIntents

/// 11-24：捷徑 App／動作按鈕／Siri 看得到的「Orbit42 開始說話」（設定 › 動作按鈕 › 捷徑 › Orbit42）
struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListenIntent(),
                    phrases: ["用 \(.applicationName) 說話", "\(.applicationName) 開始說話", "叫 \(.applicationName)"],
                    shortTitle: "開始說話", systemImageName: "waveform")
    }
}
