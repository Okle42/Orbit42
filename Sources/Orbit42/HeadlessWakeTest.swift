import AppKit
import WebKit

// 測試（11-26 版面變形）：ORBIT_OFFSCREEN=1 ORBIT_TEST_HEADLESS_WAKE=1
// ⇒ 開一顆衛星（裡面每 0.5 秒印 stty size）→ 收起 → 照背景 session 那條路把它標成 headless、固定 110×36
// → 再顯示（showSat）→ 把衛星視窗改窄 → 印出程式看到的行列數；修好時應該不是 110 欄、而且會跟著變窄
extension OrbitWindow {
    func runHeadlessWakeTest(_ env: [String: String], test: Bool) {
        guard test, env["ORBIT_TEST_HEADLESS_WAKE"] != nil else { return }
        @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        func size(_ id: String, _ tag: String, then: @escaping @MainActor () -> Void) {
            let v = host.view(for: id)
            v.evaluateJavaScript("(window.orbitTest.screen()||'').trim().split('\\n').filter(l=>/^\\d+ \\d+$/.test(l.trim())).pop()||'?'") { r, _ in
                MainActor.assumeIsolated { print("headless-wake \(tag): stty=\(r ?? "nil") win=\(self.satWins[id]?.frame.size ?? .zero)"); fflush(stdout); then() }
            }
        }
        after(3) { [weak self] in
            guard let self else { return }
            let id = self.host.runCommand(name: "欄數測試", brain: .claude, command: "while true; do stty size; sleep 0.5; done")
            after(4) {
                size(id, "1 一般") {
                    self.host.testMakeHeadless(id)                        // 跟 Host.swift 背景 session 那條路一樣：110×36＋網頁標 headless
                    after(1.5) {
                        size(id, "2 標成 headless") {
                            self.showSat(id)                               // 顯示出來 ⇒ 修好的話會叫網頁重新量
                            after(2.5) {
                                size(id, "3 顯示後") {
                                    if let w = self.satWins[id] { w.frame.size.width -= 300; w.needsLayout = true }
                                    after(2.5) { size(id, "4 改窄後") { self.host.shutdown(); exit(0) } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
