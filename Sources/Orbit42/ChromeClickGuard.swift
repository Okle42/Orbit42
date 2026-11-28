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

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」。20:25 實測（秘書代關 Keng 的 Chrome、open -a 模擬點圖示）：
/// 不是被導去衛星背後的無頭 Chrome（無頭那支根本沒在 LaunchServices 登記），而是 Chrome 正常啟動了、卻沒開出一般視窗。
/// ⇒ Orbit42 看到桌面 Chrome 啟動（或剛啟動不久被叫到前面）3 秒、6 秒還是沒有一般視窗，就用 Chrome 自己的轉送：
///    再跑一次 `Google Chrome --new-window`（不帶設定檔參數＝Keng 平常的設定檔），新程序把「開新視窗」交給在跑的那支後自己結束。
///    不用 AppleScript（Orbit42 沒有 Apple Events 權限，會跳權限或被擋）。新視窗會順便把上次的分頁叫回來（20:3x 實測 make new window 也是）。
/// 另外：登入用的 Chrome 視窗全關了、程式還留著佔住衛星的設定檔 ⇒ 把它結束，衛星網頁面板才接得回來
@MainActor
final class ChromeClickGuard {
    static let shared = ChromeClickGuard()

    /// 這支 Chrome 要不要幫它開視窗：是桌面 Chrome（不是衛星背後那支、不是登入用那支）、剛啟動 15 秒內、沒有一般視窗、這次啟動還沒幫過
    nonisolated static func needsWindow(pid: pid_t, bundle: String?, headless: pid_t, login: pid_t?, windows: Int,
                                        sinceLaunch: TimeInterval, alreadyHelped: Bool) -> Bool {
        guard bundle == "com.google.Chrome", pid > 0, pid != headless, pid != login else { return false }
        return windows == 0 && sinceLaunch <= 15 && !alreadyHelped
    }
    /// 登入用的 Chrome 留在背景、沒有視窗多久了要結束它：連續 n 次（每 2 秒一次）看到沒視窗；剛開的前幾秒視窗還沒出來不算
    nonisolated static func shouldQuitIdleLogin(noWindowStreak: Int, sinceLaunch: TimeInterval) -> Bool {
        sinceLaunch >= 8 && noWindowStreak >= 2
    }
    /// 轉送「開新視窗」用的參數：不帶 --user-data-dir ⇒ 交給用 Keng 平常設定檔在跑的那支
    nonisolated static let newWindowArgs = ["--new-window"]

    /// 這支程序有幾個一般視窗（含縮到 Dock 的；Chrome 沒視窗時只剩 1920×30 的條狀視窗，不算）
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

    private var started = false
    private var launched: [pid_t: (at: Date, helped: Bool)] = [:]
    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { note in
                guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier == "com.google.Chrome" else { return }
                let pid = a.processIdentifier, launch = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { ChromeClickGuard.shared.seen(pid, launch: launch) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = a.processIdentifier
            MainActor.assumeIsolated { _ = ChromeClickGuard.shared.launched.removeValue(forKey: pid) }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { ChromeClickGuard.shared.watchLogin() } }
    }

    private func seen(_ pid: pid_t, launch: Bool) {
        if launch { launched[pid] = (Date(), false); OrbitLog.write("chrome-click.log", "桌面 Chrome 啟動 pid \(pid)") }
        guard launched[pid] != nil else { return }        // Orbit42 開著之前就在跑的：不管
        for s in [3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { ChromeClickGuard.shared.check(pid) } }
        }
    }
    private func check(_ pid: pid_t) {
        guard let rec = launched[pid], kill(pid, 0) == 0 else { return }
        let n = Self.windowCount(pid), since = Date().timeIntervalSince(rec.at)
        guard Self.needsWindow(pid: pid, bundle: "com.google.Chrome", headless: ChromeBrowser.shared.pid, login: loginPid, windows: n,
                               sinceLaunch: since, alreadyHelped: rec.helped) else { return }
        launched[pid]?.helped = true
        guard let app = ChromeBrowser.appURL else { return }
        let p = Process()
        p.executableURL = app.appendingPathComponent("Contents/MacOS/Google Chrome")
        p.arguments = Self.newWindowArgs
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { t in
            let code = t.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
                OrbitLog.write("chrome-click.log", "轉送結束碼 \(code)；Chrome \(pid) 現在有 \(Self.windowCount(pid)) 個視窗")
            } }
        }
        do { try p.run(); OrbitLog.write("chrome-click.log", "Chrome \(pid) 啟動 \(String(format: "%.1f", since)) 秒還沒有視窗 ⇒ 轉送 --new-window") }
        catch { OrbitLog.write("chrome-click.log", "轉送 --new-window 失敗：\(error.localizedDescription)") }
    }

    // 登入用的 Chrome：按紅叉只關視窗、程式留著 ⇒ 開了 8 秒後連續 2 次沒視窗就結束（衛星網頁在等它讓出設定檔）
    private var loginSeen: (pid: pid_t, at: Date, streak: Int)?
    private func watchLogin() {
        guard let p = loginPid else { loginSeen = nil; return }
        if loginSeen?.pid != p { loginSeen = (p, Date(), 0) }
        loginSeen!.streak = Self.windowCount(p) == 0 ? loginSeen!.streak + 1 : 0
        if Self.shouldQuitIdleLogin(noWindowStreak: loginSeen!.streak, sinceLaunch: Date().timeIntervalSince(loginSeen!.at)) {
            OrbitLog.write("chrome-click.log", "結束登入用的 Chrome \(p)：視窗都關了、程式還留著佔住衛星的設定檔")
            loginSeen = nil
            if let r = NSRunningApplication(processIdentifier: p) { r.terminate() } else { kill(p, SIGTERM) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if kill(p, 0) == 0 { kill(p, SIGTERM) } }
        }
    }
}
