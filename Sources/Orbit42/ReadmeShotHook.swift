import AppKit

// README 截圖用的螢幕外掛勾（11-26）：
//   ORBIT_OFFSCREEN=1 ORBIT_CHROME_PROFILE=<空資料夾> ORBIT_TEST_README_WEB="<網址>@<png>" .build/debug/Orbit42
// ⇒ 開一顆示範衛星（終端機印幾行假輸出）、在它裡面開 Chrome 網頁面板，載完把這顆衛星的視窗截下來（Chrome 畫面另外疊上去）後結束。
// 網址請用公開或自製的示範頁；ORBIT_CHROME_PROFILE 指到空資料夾，不碰平常登入過的 Chrome 設定檔。
extension OrbitWindow {
    func runReadmeShot(_ env: [String: String], test: Bool) {
        guard test, let spec = env["ORBIT_TEST_README_WEB"], let at = spec.lastIndex(of: "@"),
              let url = WebPane.parse(String(spec[..<at])) else { return }
        let out = String(spec[spec.index(after: at)...])
        @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        let demo = env["ORBIT_TEST_README_CMD"] ?? "echo 示範衛星; sleep 90"
        after(3) { [weak self] in
            guard let self else { return }
            let id = self.host.runCommand(name: env["ORBIT_TEST_README_NAME"] ?? "Claude · 網站改版", brain: .claude, command: demo)
            self.openWeb(url, sat: id)
            after(Double(env["ORBIT_TEST_README_WAIT"] ?? "") ?? 8) {
                guard let w = self.satWins[id], let p = self.moonViews(id)["web"] as? WebPane else { print("readme: no pane"); exit(1) }
                let img = NSImage(size: w.bounds.size)
                if let rep = w.bitmapImageRepForCachingDisplay(in: w.bounds) { w.cacheDisplay(in: w.bounds, to: rep); img.addRepresentation(rep) }
                let final = NSImage(size: w.bounds.size)
                final.lockFocus()
                img.draw(in: w.bounds)
                if let cg = p.web.snapshot { NSImage(cgImage: cg, size: .zero).draw(in: w.convert(p.web.bounds, from: p.web)) }
                final.unlockFocus()
                if let t = final.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
                print("readme shot \(out) win=\(w.bounds.size) web=\(p.web.bounds.size) frames=\(p.web.frames) url=\(p.currentURL)"); fflush(stdout)
                self.dropMoon(id, "web"); ChromeBrowser.shared.quit()
                after(2) { self.host.shutdown(); exit(0) }
            }
        }
    }
}
