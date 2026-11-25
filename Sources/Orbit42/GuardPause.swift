import AppKit
import LocalAuthentication
import ShoWorkApp
import ShoWorkCore

/// 選單「暫停防冒充檢查⋯」：Touch ID 或 Mac 密碼過了才暫停，30 分鐘後自動恢復。開、關都通知、留紀錄。
/// 狀態只在記憶體裡，showork 來問時回答（GuardOff）。
final class PauseState: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date?
    var until: Date? { get { lock.withLock { date } } set { lock.withLock { date = newValue } } }
}
@MainActor final class GuardPause: NSObject, NSMenuItemValidation {
    static let shared = GuardPause()
    private let item = NSMenuItem(title: "暫停防冒充檢查⋯", action: #selector(toggle), keyEquivalent: "")
    private let state = PauseState()
    private var timer: Timer?
    private var say: (String) -> Void = { _ in }

    func start(say: @escaping (String) -> Void) {
        self.say = say
        let st = state
        GuardOff.local = { st.until }
        if GuardOff.serve(until: { st.until }) == nil { NSLog("guard.sock 開不起來：暫停功能不能用，檢查照常") }
        item.target = self
        if !EditMenu.addAppItem(item) {
            let bar = NSApp.mainMenu ?? NSMenu(), top = NSMenuItem(), m = NSMenu(title: "Orbit42")
            m.addItem(item); top.submenu = m; bar.insertItem(top, at: 0)
            if NSApp.mainMenu == nil { NSApp.mainMenu = bar }
        }
    }
    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        m.title = GuardOff.current().map { "恢復防冒充檢查（暫停到 \($0.formatted(date: .omitted, time: .shortened))）" } ?? "暫停防冒充檢查⋯"
        return true
    }
    @objc func toggle() {
        if GuardOff.current() != nil {
            state.until = nil; timer?.invalidate()
            return tell("防冒充檢查已恢復", "resume")
        }
        let ctx = LAContext(); ctx.localizedCancelTitle = "取消"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "暫停 AI 防冒充檢查 30 分鐘") { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ok ? self.pause() : self.say("沒有暫停防冒充檢查") } }
        }
    }
    private func pause() {
        let until = Date(timeIntervalSinceNow: GuardOff.limit - 5)
        state.until = until
        arm(until)
        tell("防冒充檢查暫停到 \(until.formatted(date: .omitted, time: .shortened))，之後自動恢復", "pause")
    }
    private func arm(_ until: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow + 1), repeats: false) { _ in
            MainActor.assumeIsolated { if GuardOff.current() == nil { self.state.until = nil; self.tell("防冒充檢查已自動恢復", "expire") } }
        }
    }
    private func tell(_ s: String, _ ev: String) {
        say(s)
        Caller.record("guard-\(ev)", sid: "app")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(s)\" with title \"Orbit42\""]; try? p.run()
    }
}
