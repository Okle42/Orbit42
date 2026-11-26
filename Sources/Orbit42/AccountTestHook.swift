import AppKit

// 真的登一次 Google 的測試（11-26）：
//   ORBIT_OFFSCREEN=1 ORBIT_TEST_GOOGLE_LOGIN=1 [ORBIT_ACCOUNT_KEYCHAIN=<測試用項目>] .build/debug/Orbit42
// ⇒ 主視窗照樣在螢幕外，只會跳出 Google 的登入視窗讓人選帳號；登完印出 Firebase 帳號、換一次新憑證、登出（清掉鑰匙圈）後結束。
extension OrbitWindow {
    func runAccountTest(_ env: [String: String], test: Bool) {
        guard test, env["ORBIT_TEST_GOOGLE_LOGIN"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated {
            let acct = OrbitAccount.shared
            guard acct.config != nil else { print("google: 沒有設定（Info.plist 或 ORBIT_FIREBASE_API_KEY／ORBIT_GOOGLE_CLIENT_ID）"); fflush(stdout); exit(1) }
            // 系統登入視窗是掛在某個視窗上的附屬視窗：主視窗在螢幕外就看不到 ⇒ 另開一個看得到的小視窗只放它
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Orbit42 · Google 登入測試"; w.isReleasedWhenClosed = false; w.center()
            let label = NSTextField(labelWithString: "在跳出的 Google 視窗選帳號；登完這個測試視窗會自己關掉")
            label.frame = NSRect(x: 20, y: 48, width: 480, height: 24); w.contentView?.addSubview(label)
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            acct.anchor = w
            Task { @MainActor in
                do {
                    let info = try await acct.signIn()
                    print("google: 登入成功 uid=\(info.uid) email=\(info.email) name=\(info.name)")
                    let t = try await acct.freshIDToken()
                    print("google: 換新憑證成功（長度 \(t.count)）")
                    if env["ORBIT_TEST_GOOGLE_KEEP"] == nil { acct.signOut(); print("google: 已登出，鑰匙圈清掉=\(acct.current == nil)") }
                    fflush(stdout); exit(0)
                } catch { print("google: 失敗 \(error.localizedDescription)"); fflush(stdout); exit(2) }
            }
        } }
    }
}
