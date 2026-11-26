import AppKit
import Orbit42App

/// 衛星 Chrome 登入 Google（11-26 Keng：衛星裡看 YouTube／Gmail 不用再登）。
/// Google 會擋無頭瀏覽器登入 ⇒ 暫時關掉衛星背後的無頭 Chrome，用「同一個設定檔」開一個正常的 Chrome 視窗讓人親手登入；
/// 關掉這個視窗後，登入紀錄留在設定檔裡，衛星裡的網頁下次載入就是登入狀態（11-26 實測：一般 Chrome 存的 cookie 無頭讀得到）。
/// 入口在 App 選單（Orbit42 → 在衛星的 Chrome 登入 Google⋯），畫面不加按鈕。
@MainActor
final class ChromeGoogleLogin: NSObject {
    static let shared = ChromeGoogleLogin()
    nonisolated static let loginURL = "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fwww.youtube.com%2F"
    private(set) var proc: Process?

    func installMenu() {
        let i = NSMenuItem(title: "在衛星的 Chrome 登入 Google⋯", action: #selector(open), keyEquivalent: "")
        i.target = self; _ = EditMenu.addAppItem(i)
    }

    /// 正常 Chrome 的啟動參數（同一個設定檔；不帶 headless、不帶遙控管線）
    static func arguments(profile: String, url: String = loginURL) -> [String] {
        ["--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--new-window", url]
    }

    @objc func open() {
        if let p = proc, p.isRunning { NSRunningApplication(processIdentifier: p.processIdentifier)?.activate(); return }
        guard let app = ChromeBrowser.appURL else { return OrbitWindow.shared.toast("這台 Mac 沒有裝 Google Chrome") }
        // 同一個設定檔同時只能給一支 Chrome 用：先關掉衛星背後的無頭 Chrome（衛星網頁之後重新載入時會自己再開）
        ChromeBrowser.shared.quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { self.launch(app) } }
    }

    private func launch(_ app: URL) {
        try? FileManager.default.createDirectory(atPath: ChromeBrowser.profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/Google Chrome")
        p.arguments = Self.arguments(profile: ChromeBrowser.profile)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.proc = nil
                OrbitWindow.shared.toast("Google 登入已記住：衛星裡的網頁重新載入就是登入狀態")
            } }
        }
        do { try p.run(); proc = p; OrbitWindow.shared.toast("在跳出的 Chrome 視窗登入 Google，登完把那個視窗關掉（⌘Q）") }
        catch { OrbitWindow.shared.toast("Chrome 開不起來：\(error.localizedDescription)") }
    }
}
