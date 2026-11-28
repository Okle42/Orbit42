import AppKit

// 測試（11-28 Keng「重開會把用到一半的 3D 關掉」）：ORBIT_OFFSCREEN=1 ORBIT_TEST_KEEP3D=<檔1>|<檔2>
// ⇒ 開一顆假衛星（/bin/sleep）→ 依序開兩個 3D 檔 → 照關機那條路記下（addModel）→ 把 3D 面板整個關掉
// → 照重開那條路開回來（reopenModel）→ 檢查：下拉選單兩個檔、順序一樣、顯示的是第 2 個、面板有展開
// 第二輪：先收起面板再記 ⇒ 開回來面板要在、但不展開；第三輪：清單裡有不存在的檔 ⇒ 略過不當掉
extension OrbitWindow {
    func runKeep3DTest(_ env: [String: String], test: Bool) {
        guard test, let spec = env["ORBIT_TEST_KEEP3D"] else { return }
        let files = spec.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        @MainActor func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } } }
        var fails = 0
        @MainActor func check(_ name: String, _ ok: Bool, _ got: String) { print("keep3d \(ok ? "PASS" : "FAIL") \(name): \(got)"); fflush(stdout); if !ok { fails += 1 } }
        @MainActor func state(_ id: String) -> (names: [String], cur: String, shown: String) {
            let v = moonViews(id)["3d"] as? ModelView
            return (v?.history.map(\.lastPathComponent) ?? [], v?.url?.lastPathComponent ?? "-", moonShownKind(id) ?? "-")
        }
        after(3) {
            let id = self.host.runCommand(name: "測試衛星", brain: .claude, command: "/bin/sleep 600")
            after(2) {
                for f in files { self.openView(f, sat: id) }
                after(4) {
                    let want = files.map(\.lastPathComponent)
                    var e: [String: String] = [:]; self.host.addModel(&e, id)
                    self.dropMoon(id, "3d")
                    check("關掉後面板不在", self.moonViews(id)["3d"] == nil, "\(self.moonViews(id).keys.sorted())")
                    self.host.reopenModel(e, sat: id)
                    after(4) {
                        let s = state(id)
                        check("展開的面板開回來", s.names == want && s.cur == want.last && s.shown == "3d", "\(s)")
                        self.tuckMoon(id)
                        var e2: [String: String] = [:]; self.host.addModel(&e2, id)
                        self.dropMoon(id, "3d")
                        e2["3d"] = (e2["3d"] ?? "") + "\n/tmp/不存在的檔-keep3d.step"
                        self.host.reopenModel(e2, sat: id)
                        after(5) {
                            let s2 = state(id)
                            check("收起的面板開回來但不展開＋略過不存在的檔", s2.names == want && s2.shown == "-", "\(s2)")
                            var e3: [String: String] = [:]; self.host.addModel(&e3, id)
                            self.dropMoon(id, "3d")
                            var e4: [String: String] = [:]; self.host.addModel(&e4, id)
                            check("沒開 3D 就不記", e4["3d"] == nil && e3["3d"] != nil, "\(e4)")
                            print("keep3d done fails=\(fails)"); fflush(stdout); exit(fails == 0 ? 0 : 1)
                        }
                    }
                }
            }
        }
    }
}
