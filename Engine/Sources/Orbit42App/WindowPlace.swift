import AppKit

/// 11-25 Keng：重開後視窗回到原本的螢幕、位置與大小。
/// 按「螢幕組合」分開記：電視關掉時系統會把視窗趕到別的螢幕，不可蓋掉電視開著時的位置。
public enum WindowPlace {
    public static func key(_ screens: [NSRect]) -> String {
        let s = screens.map { [$0.minX, $0.minY, $0.width, $0.height].map { String(Int($0.rounded())) }.joined(separator: ",") }.sorted()
        return "orbit.window.frame|" + s.joined(separator: "|")
    }
    /// 存的框拿來用之前先校正：在哪個螢幕最多就收進那個螢幕的可用範圍；壞值、完全不在螢幕上 ⇒ nil（照舊置中）
    public static func fit(_ f: NSRect, visible: [NSRect], min: NSSize = NSSize(width: 480, height: 320)) -> NSRect? {
        guard [f.minX, f.minY, f.width, f.height].allSatisfy({ $0.isFinite }), f.width >= min.width, f.height >= min.height else { return nil }
        func area(_ r: NSRect) -> CGFloat { let i = r.intersection(f); return i.isNull ? 0 : i.width * i.height }
        guard let v = visible.max(by: { area($0) < area($1) }), area(v) > 0 else { return nil }
        let w = Swift.min(f.width, v.width), h = Swift.min(f.height, v.height)
        return NSRect(x: Swift.min(Swift.max(f.minX, v.minX), v.maxX - w), y: Swift.min(Swift.max(f.minY, v.minY), v.maxY - h), width: w, height: h)
    }
    public static func load(_ ud: UserDefaults, screens: [NSRect], visible: [NSRect]) -> NSRect? {
        ud.string(forKey: key(screens)).flatMap { fit(NSRectFromString($0), visible: visible) }
    }
    public static func save(_ f: NSRect, _ ud: UserDefaults, screens: [NSRect]) { ud.set(NSStringFromRect(f), forKey: key(screens)) }
}
