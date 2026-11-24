import AppKit
import CryptoKit
import LocalAuthentication
import ShoWorkApp
import ShoWorkCore

/// 選單「暫停防冒充檢查⋯」：Touch ID 或 Mac 密碼過了才暫停，30 分鐘後自動恢復。開、關都通知、留紀錄。
/// 簽章鑰匙在安全晶片，每次簽都要系統驗證（別的程式載入同一把也會跳驗證）。
@MainActor final class GuardPause: NSObject, NSMenuItemValidation {
    static let shared = GuardPause()
    private let item = NSMenuItem(title: "暫停防冒充檢查⋯", action: #selector(toggle), keyEquivalent: "")
    private var timer: Timer?
    private var say: (String) -> Void = { _ in }
    static var blob: URL { GuardOff.dir.appendingPathComponent("a-off.key") }

    func start(say: @escaping (String) -> Void) {
        self.say = say
        item.target = self
        if let app = NSApp.mainMenu?.items.first?.submenu {
            app.insertItem(item, at: min(1, app.items.count))
        } else {
            let bar = NSApp.mainMenu ?? NSMenu(), top = NSMenuItem(), m = NSMenu(title: "Orbit42")
            m.addItem(item); top.submenu = m; bar.insertItem(top, at: 0)
            if NSApp.mainMenu == nil { NSApp.mainMenu = bar }
        }
        if let o = GuardOff.current(now: Date()) { arm(o.until) }
    }
    func validateMenuItem(_ m: NSMenuItem) -> Bool {
        m.title = GuardOff.current(now: Date()).map { "恢復防冒充檢查（暫停到 \($0.until.formatted(date: .omitted, time: .shortened))）" } ?? "暫停防冒充檢查⋯"
        return true
    }
    @objc func toggle() {
        if GuardOff.current(now: Date()) != nil {
            try? FileManager.default.removeItem(at: GuardOff.file)
            return tell("防冒充檢查已恢復", "resume")
        }
        let ctx = LAContext(); ctx.localizedCancelTitle = "取消"
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "暫停 AI 防冒充檢查 30 分鐘") { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ok ? self.pause(ctx) : self.say("沒有暫停防冒充檢查") } }
        }
    }
    private func pause(_ ctx: LAContext) {
        let until = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + GuardOff.limit - 5).rounded(.down))
        do {
            let k = try Self.key(ctx)
            try GuardOff.save(GuardOff(until: until, sig: try k.signature(for: GuardOff.message(until)).derRepresentation), key: k.publicKey.x963Representation)
        } catch { return say("沒有暫停：\(error.localizedDescription)") }
        guard GuardOff.current(now: Date()) != nil else { return say("沒有暫停：簽章沒通過") }
        arm(until)
        tell("防冒充檢查暫停到 \(until.formatted(date: .omitted, time: .shortened))，之後自動恢復", "pause")
    }
    private static func key(_ ctx: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let d = FileManager.default.contents(atPath: blob.path), let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: d, authenticationContext: ctx) { return k }
        var e: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &e) else { throw e!.takeRetainedValue() as Error }
        let k = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac, authenticationContext: ctx)
        try FileManager.default.createDirectory(at: GuardOff.dir, withIntermediateDirectories: true)
        try k.dataRepresentation.write(to: blob, options: .atomic)
        return k
    }
    private func arm(_ until: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow + 1), repeats: false) { _ in
            MainActor.assumeIsolated { if GuardOff.current(now: Date()) == nil { self.tell("防冒充檢查已自動恢復", "expire") } }
        }
    }
    private func tell(_ s: String, _ ev: String) {
        say(s)
        Caller.record("guard-\(ev)", sid: "app")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(s)\" with title \"Orbit42\""]; try? p.run()
    }
}
