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
        let i = NSMenuItem(title: "在衛星的 Chrome 登入 Google⋯", action: #selector(openFromMenu), keyEquivalent: "")
        i.target = self; _ = EditMenu.addAppItem(i)
    }

    /// 正常 Chrome 的啟動參數（同一個設定檔；不帶 headless、不帶遙控管線）
    static func arguments(profile: String, url: String = loginURL) -> [String] {
        ["--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--new-window", url]
    }

    private var after: (() -> Void)?
    private var waiters: [() -> Void] = []
    /// 登入視窗開著：自己開的那個還在跑，或設定檔被別支 Chrome 佔著（Orbit42 重開前開的那個視窗，新程序不認得）
    var isOpen: Bool { proc?.isRunning == true || Self.lockedByOther() }
    /// Chrome 開著設定檔時會留 SingletonLock（指向「主機名-程序編號」）；程序還活著、又不是衛星背後那支無頭 Chrome ⇒ 被別人佔著
    nonisolated static func lockOwner(_ profile: String) -> pid_t? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: profile + "/SingletonLock"),
              let n = dest.split(separator: "-").last.flatMap({ Int32($0) }), n > 0 else { return nil }
        return n
    }
    static func lockedByOther() -> Bool {
        guard let p = lockOwner(ChromeBrowser.profile), p != ChromeBrowser.shared.pid else { return false }
        return kill(p, 0) == 0
    }
    /// 登入視窗關掉之後要做的事（衛星網頁面板在等它讓出設定檔）
    func whenClosed(_ f: @escaping () -> Void) {
        waiters.append(f)
        guard proc?.isRunning != true, !polling else { return }      // 不是自己開的視窗 ⇒ 沒有結束通知，每 2 秒看一次鎖還在不在
        polling = true
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in MainActor.assumeIsolated {
            guard let self, !Self.lockedByOther() else { return }
            t.invalidate(); self.polling = false
            let w = self.waiters; self.waiters = []; w.forEach { $0() }
        } }
    }
    private var polling = false
    @objc func openFromMenu() { open(url: Self.loginURL) }
    /// url：正常 Chrome 視窗一開就停在哪一頁（網站的登入頁）；then：視窗關掉、登入記好之後要做的事（例如面板重新載入原頁）
    func open(url: String, then: (() -> Void)? = nil) {
        if let then { after = then }
        if let p = proc, p.isRunning { NSRunningApplication(processIdentifier: p.processIdentifier)?.activate(); return }
        guard let app = ChromeBrowser.appURL else { return OrbitWindow.shared.toast("這台 Mac 沒有裝 Google Chrome") }
        // 同一個設定檔同時只能給一支 Chrome 用：先關掉衛星背後的無頭 Chrome（衛星網頁之後重新載入時會自己再開）
        ChromeBrowser.shared.quit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { self.launch(app, url: url) } }
    }

    private func launch(_ app: URL, url: String) {
        try? FileManager.default.createDirectory(atPath: ChromeBrowser.profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/Google Chrome")
        p.arguments = Self.arguments(profile: ChromeBrowser.profile, url: url)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.proc = nil
                let f = self.after; self.after = nil
                let w = self.waiters; self.waiters = []
                OrbitWindow.shared.toast("Google 登入已記住：衛星裡的網頁重新載入就是登入狀態")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { w.forEach { $0() }; f?() } }
            } }
        }
        do { try p.run(); proc = p; OrbitWindow.shared.toast("在跳出的 Chrome 視窗登入（可以用 Google），登完按 ⌘Q 關掉那個視窗，衛星網頁會自己重新載入") }
        catch { after = nil; OrbitWindow.shared.toast("Chrome 開不起來：\(error.localizedDescription)") }
    }
}
