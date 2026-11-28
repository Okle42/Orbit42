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

/// 11-28 Keng「桌面 Chrome 關掉後點圖示沒反應」。20:25 實測：Chrome 有啟動、卻沒開出一般視窗（不是被導去衛星背後的無頭 Chrome）。
/// 32306a2 曾用「沒視窗就轉送 --new-window 補開」繞過；Keng 11-28「改成把功能修好就好…未來也不用補檢查或者是再開什麼」⇒ 補開拿掉，
/// 這裡只留紀錄（chrome-click.log：桌面 Chrome 什麼時候啟動、1.5／6 秒時有幾個視窗），給查根本原因用。
/// 根本原因（20:53 帶 --enable-logging 重現，chrome_debug.log 有 kProfilePickerView）：Keng 有 3 個 Chrome 設定檔，
/// Chrome 每次啟動先開「設定檔選擇器」，而且開在左邊電視上 ⇒ 主螢幕看起來沒反應。跟 Orbit42 無關。
/// 20:57 已把 Keng 的 Chrome 設定 Local State「profile.show_picker_on_startup」改 false（原檔備份在 Local State.bak-before-picker-off-20261128），
/// 重開 0.6 秒就在主螢幕開出視窗、分頁都回來
/// 另外：登入用的 Chrome 視窗全關了、程式還留著佔住衛星的設定檔 ⇒ 把它結束，衛星網頁面板才接得回來（跟上面那題無關，保留）
@MainActor
final class ChromeClickGuard {
    static let shared = ChromeClickGuard()

    /// 登入用的 Chrome 留在背景、沒有視窗多久了要結束它：連續 n 次（每 2 秒一次）看到沒視窗；剛開的前幾秒視窗還沒出來不算
    nonisolated static func shouldQuitIdleLogin(noWindowStreak: Int, sinceLaunch: TimeInterval) -> Bool {
        sinceLaunch >= 8 && noWindowStreak >= 2
    }
    /// 桌面 Chrome 啟動後第幾秒記一次視窗數（只記、不動它）
    nonisolated static let observeDelays: [TimeInterval] = [1.5, 6.0]

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
    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier == "com.google.Chrome" else { return }
            let pid = a.processIdentifier
            MainActor.assumeIsolated { ChromeClickGuard.shared.observe(pid) }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { ChromeClickGuard.shared.watchLogin() } }
    }

    private func observe(_ pid: pid_t) {
        guard pid != ChromeBrowser.shared.pid, pid != loginPid else { return }
        let args = Self.arguments(pid)
        OrbitLog.write("chrome-click.log", "桌面 Chrome 啟動 pid \(pid)，參數：\(args.isEmpty ? "（無）" : args.joined(separator: " "))")
        for s in Self.observeDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated {
                guard kill(pid, 0) == 0 else { return }
                OrbitLog.write("chrome-click.log", "Chrome \(pid) 啟動 \(s) 秒：\(Self.windowCount(pid)) 個一般視窗")
            } }
        }
    }
    /// 程序的啟動參數（不含程式路徑）；查「為什麼沒開視窗」時看是不是被帶了 --no-startup-window 之類
    nonisolated static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var parts: [String] = [], cur = [UInt8](), i = 4
        while i < size, buf[i] != 0 { i += 1 }                // 執行檔路徑
        while i < size, buf[i] == 0 { i += 1 }                // 補齊用的 0
        while i < size, parts.count < argc {
            if buf[i] == 0 { parts.append(String(decoding: cur, as: UTF8.self)); cur = [] } else { cur.append(buf[i]) }
            i += 1
        }
        return Array(parts.dropFirst())
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
