import AppKit

/// 11-24 Keng「圖示分深色跟淺色，自動符合系統」：
/// Finder／桌面／Launchpad 用 Assets.car（assets/Orbit42.icon，含深色外觀，系統自己切）；
/// App 開著時 Dock 上的圖示另外跟著深淺色換（macOS「圖示樣式」設成預設時，系統不會因為深色模式就換成深色圖示）。
@MainActor final class DockIcon {
    static let shared = DockIcon()
    private var obs: NSKeyValueObservation?
    private var last: Bool?

    func start() {
        apply()
        obs = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DockIcon.shared.apply() } }
        }
    }

    private func apply() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != last else { return }
        last = dark
        guard let url = Bundle.main.url(forResource: dark ? "Orbit42-dark" : "Orbit42-light", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return }      // swift run（沒有 .app）時沒有資源就維持預設
        NSApp.applicationIconImage = img
    }
}
