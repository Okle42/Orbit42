import AppKit

/// 寫進 ~/Library/Logs/Orbit42/<檔名>（11-28 Keng「網頁重開沒開回來」查不到原因：App 的 print 沒寫進任何地方）。
/// 測試用 ORBIT_LOG_DIR 換資料夾，不碰真正的紀錄
enum OrbitLog {
    nonisolated static var dir: String {
        ProcessInfo.processInfo.environment["ORBIT_LOG_DIR"] ?? NSHomeDirectory() + "/Library/Logs/Orbit42"
    }
    nonisolated static func write(_ file: String, _ line: String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd HH:mm:ss.SSS"
        let path = dir + "/" + file, text = f.string(from: Date()) + " " + line + "\n"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) }
    }
    /// 重開時開回網頁／3D 的每一步、背後 Chrome 的開關
    nonisolated static func restore(_ line: String) { write("restore.log", line) }
}

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」：衛星背後的 Chrome 跟桌面 Chrome 是同一個 App（同 bundle id），
/// macOS 會把「開 Chrome」交給已經在跑、但沒有視窗的那一支（衛星的無頭 Chrome，或登入用、按紅叉後留在背景的 Chrome）。
/// Orbit42 看到這兩支被叫到前面、而且沒有視窗 ⇒ 另開一份新的正常 Chrome（不帶設定檔參數 ⇒ Keng 平常的設定檔、他的登入）。
/// 另外：登入用的 Chrome 視窗全關了、程式還留著佔住設定檔 ⇒ 把它結束，衛星網頁面板才接得回來
@MainActor
final class ChromeClickGuard {
    static let shared = ChromeClickGuard()

    enum Action: Equatable { case none, openDesktop, openDesktopAndQuitLogin }
    /// 判斷：被叫到前面的是哪一支 Chrome、它有沒有視窗
    nonisolated static func decide(activated: pid_t, bundle: String?, headless: pid_t, login: pid_t?, windows: Int) -> Action {
        guard bundle == "com.google.Chrome", activated > 0 else { return .none }
        if activated == headless { return .openDesktop }                  // 無頭那支本來就沒有視窗
        if let login, activated == login, windows == 0 { return .openDesktopAndQuitLogin }
        return .none                                                       // Keng 自己的 Chrome，或登入視窗還開著
    }
    /// 登入用的 Chrome 留在背景、沒有視窗多久了要結束它：連續 n 次（每 2 秒一次）看到沒視窗；剛開的前幾秒視窗還沒出來不算
    nonisolated static func shouldQuitIdleLogin(noWindowStreak: Int, sinceLaunch: TimeInterval) -> Bool {
        sinceLaunch >= 8 && noWindowStreak >= 2
    }

    /// 這支程序在畫面上（含縮到 Dock 的）有幾個一般視窗
    nonisolated static func windowCount(_ pid: pid_t) -> Int {
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.filter { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (b["Width"] ?? 0) >= 100 && (b["Height"] ?? 0) >= 100
        }.count
    }

    /// 登入用的那支（自己開的，或 Orbit42 重開前開的、佔著設定檔的那支）
    var loginPid: pid_t? {
        if let p = ChromeGoogleLogin.shared.proc, p.isRunning { return p.processIdentifier }
        if let p = ChromeGoogleLogin.lockOwner(ChromeBrowser.profile), p != ChromeBrowser.shared.pid, kill(p, 0) == 0 { return p }
        return nil
    }

    private var started = false, lastOpen = Date.distantPast
    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = a.processIdentifier, bundle = a.bundleIdentifier
            MainActor.assumeIsolated { ChromeClickGuard.shared.activated(pid, bundle) }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { ChromeClickGuard.shared.watchLogin() } }
    }

    private func activated(_ pid: pid_t, _ bundle: String?) {
        guard bundle == "com.google.Chrome" else { return }
        let login = loginPid
        let act = Self.decide(activated: pid, bundle: bundle, headless: ChromeBrowser.shared.pid, login: login, windows: Self.windowCount(pid))
        OrbitLog.write("chrome-click.log", "叫到前面 pid \(pid)（無頭 \(ChromeBrowser.shared.pid)、登入 \(login.map(String.init) ?? "-")）⇒ \(act)")
        switch act {
        case .none: return
        case .openDesktop: openDesktop()
        case .openDesktopAndQuitLogin: quitLogin(pid, why: "被叫到前面但沒有視窗"); openDesktop()
        }
    }

    /// 開一份新的正常 Chrome（Keng 平常的設定檔）。已經有別支有視窗的正常 Chrome 就不重開
    func openDesktop() {
        guard Date().timeIntervalSince(lastOpen) > 3, let app = ChromeBrowser.appURL else { return }
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.google.Chrome" && $0.processIdentifier != ChromeBrowser.shared.pid && $0.processIdentifier != loginPid
        }
        if let mine = others.first(where: { Self.windowCount($0.processIdentifier) > 0 }) {
            OrbitLog.write("chrome-click.log", "桌面 Chrome \(mine.processIdentifier) 已經有視窗，叫它到前面"); mine.activate(); return
        }
        lastOpen = Date()
        let c = NSWorkspace.OpenConfiguration(); c.createsNewApplicationInstance = true; c.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: c) { a, e in
            OrbitLog.write("chrome-click.log", e.map { "開正常 Chrome 失敗：\($0.localizedDescription)" } ?? "開了正常 Chrome pid \(a?.processIdentifier ?? 0)")
        }
    }

    // 登入用的 Chrome：按紅叉只關視窗、程式留著 ⇒ 沒視窗超過 4 秒就結束（衛星網頁在等它讓出設定檔）
    private var loginSeen: (pid: pid_t, at: Date, streak: Int)?
    private func watchLogin() {
        guard let p = loginPid else { loginSeen = nil; return }
        if loginSeen?.pid != p {
            // 自己開的：從啟動算；Orbit42 重開前開的：從第一次看到算（它早就開好了，但保守一點一樣等 8 秒）
            loginSeen = (p, Date(), 0)
        }
        let n = Self.windowCount(p)
        loginSeen!.streak = n == 0 ? loginSeen!.streak + 1 : 0
        if Self.shouldQuitIdleLogin(noWindowStreak: loginSeen!.streak, sinceLaunch: Date().timeIntervalSince(loginSeen!.at)) {
            quitLogin(p, why: "視窗都關了、程式還留著佔住設定檔")
        }
    }
    private func quitLogin(_ p: pid_t, why: String) {
        OrbitLog.write("chrome-click.log", "結束登入用的 Chrome \(p)：\(why)")
        loginSeen = nil
        if let r = NSRunningApplication(processIdentifier: p) { r.terminate() } else { kill(p, SIGTERM) }
        // terminate 沒效（例如有對話框）5 秒後再送 SIGTERM
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if kill(p, 0) == 0 { kill(p, SIGTERM) } }
    }
}
