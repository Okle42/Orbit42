import AppKit
import ApplicationServices
import CoreWLAN
import Orbit42Core

/// 本機資安體檢自動跑（第二階段，T1128034721）：每週一次＋換 Wi-Fi 時；跟上次自動跑的結果不同才通知。
/// 不用 launchd（launchctl submit 會無限重跑）：Orbit42 開著就由它自己排，關著就等下次開。
@MainActor
final class SecSchedule: NSObject, CWEventDelegate {
    static let shared = SecSchedule()
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var running = false

    func start() {
        // 讀不到權限資料庫時，至少列 Orbit42 自己有的（只查、不會跳權限窗）
        SecCheck.ownPermissions = {
            var own: [String] = []
            if AXIsProcessTrusted() { own.append("輔助使用") }
            if CGPreflightScreenCaptureAccess() { own.append("螢幕錄影") }
            return own
        }
        // 每小時看一次有沒有超過一週沒跑；開 App 後 2 分鐘先看第一次（不跟開機搶資源）
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { MainActor.assumeIsolated { self.tick() } }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in MainActor.assumeIsolated { SecSchedule.shared.tick() } }
        let c = CWWiFiClient.shared()
        c.delegate = self
        try? c.startMonitoringEvent(with: .linkDidChange)
    }

    private func tick() {
        if SecCheck.weeklyDue(last: SecCheck.lastAuto()?.at) { run(reason: "每週體檢") }
    }

    // 換 Wi-Fi：連線狀態變了 ⇒ 等 20 秒（等 DHCP、DNS 穩定）再跑；連續變化只跑一次
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.pending?.cancel()
            let w = DispatchWorkItem { MainActor.assumeIsolated { SecSchedule.shared.run(reason: "換了 Wi-Fi") } }
            self.pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
        } }
    }

    func run(reason: String) {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let r = SecCheck.run()
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.running = false
                let diff = SecCheck.changes(old: SecCheck.lastAuto()?.signature, new: r)
                SecCheck.saveAuto(r)
                guard !diff.isEmpty else { return }            // 沒變化不通知
                let head = "資安體檢（\(reason)）跟上次不一樣：\(diff.count) 項"
                OrbitWindow.shared.toast(head + "。從選單「本機資安體檢⋯」看細節")
                let body = diff.prefix(3).joined(separator: "；").replacingOccurrences(of: "\"", with: "'")
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "display notification \"\(body)\" with title \"Orbit42\" subtitle \"\(head)\""]
                try? p.run()
            } }
        }
    }
}
