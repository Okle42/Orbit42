import AppKit

/// Orbit42 的品牌色（網頁那邊是 sphere.html 的 --acc；iPhone 是 App.swift 的 UIColor.ok*）
enum Palette {
    static let green = NSColor(srgbRed: 0x4f / 255.0, green: 0xc3 / 255.0, blue: 0x6a / 255.0, alpha: 1)
    static let red = NSColor(srgbRed: 0xd7 / 255.0, green: 0x26 / 255.0, blue: 0x1b / 255.0, alpha: 1)
    /// 11-28 Keng：資安體檢「注意」燈號用黃色，一眼跟「危險」紅色分開（深淺色都用這個；上面放深色字）
    static let amber = NSColor(srgbRed: 0xe8 / 255.0, green: 0xa8 / 255.0, blue: 0x1c / 255.0, alpha: 1)
}
