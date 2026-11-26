import Foundation

// 11-25 Keng：終端機滑過浮起（T1125035226）。純判斷，畫面在 Orbit42 的 main.swift。
// 只決定「誰畫在最上面、誰變暗」，從不碰焦點、打字目標、位置大小。

/// 疊放順序（最底 → 最上）：照排列順序（打開先後），秘書最後；點過／打字的那顆在上面，滑過浮起的在最上面
public enum SatStack {
    public struct Win: Equatable, Sendable {
        public var id: String, seq: Int, secretary: Bool
        public init(id: String, seq: Int, secretary: Bool = false) { self.id = id; self.seq = seq; self.secretary = secretary }
    }
    /// 排位置用：左上 → 右下
    public static func slots(_ ws: [Win]) -> [String] {
        ws.sorted { ($0.secretary ? 1 : 0, $0.seq) < ($1.secretary ? 1 : 0, $1.seq) }.map(\.id)
    }
    public static func order(_ ws: [Win], pinned: String?, lifted: String?) -> [String] {
        var out = slots(ws)
        for top in [pinned, lifted] { if let t = top, let i = out.firstIndex(of: t) { out.append(out.remove(at: i)) } }
        return out
    }
    /// 滑鼠底下看得到的那顆：照現在的疊放從上往下找 ⇒ 浮起來的那顆蓋住別顆時就是它，不會兩顆來回跳
    public static func hit(_ p: CGPoint, order: [String], frames: [String: CGRect]) -> String? { order.last { frames[$0]?.contains(p) == true } }
    /// 浮起時誰要變暗：浮起那顆和正在打字那顆以外
    public static func dimmed(_ order: [String], lifted: String?, typing: String?) -> Set<String> {
        guard let l = lifted else { return [] }
        return Set(order).subtracting([l]).subtracting(typing.map { [$0] } ?? [])
    }
}

public struct HoverLift: Equatable, Sendable {
    public static let dwell = 0.15, grace = 0.2
    public private(set) var lifted: String?
    private var cand: String?, candAt = 0.0, leaveAt: Double?
    private var mute: String??                // 打字／點擊時滑鼠停在這顆：要先移到別處才會再浮起
    public init() {}
    /// 還有事情在等（要排下一次檢查）；幾秒後
    public func due(_ now: Double) -> Double? {
        if let t = leaveAt { return max(0, t + Self.grace - now) }
        if cand != nil { return max(0, candAt + Self.dwell - now) }
        return nil
    }
    /// hover＝滑鼠底下那顆（nil＝空白處）；inside＝滑鼠在 Orbit42 視窗裡而且視窗有焦點；paused＝拖曳、捲動、組字、選單開著⋯
    public mutating func step(_ now: Double, hover: String?, inside: Bool, paused: Bool) {
        if !inside { self = HoverLift(); return }                      // 離開視窗、失焦：馬上歸位
        if paused { cand = nil; leaveAt = nil; return }                // 凍結：不浮起也不歸位，結束後重新計時
        if let m = mute { if m == hover { return }; mute = nil }
        guard let h = hover else {
            cand = nil
            guard lifted != nil else { leaveAt = nil; return }
            if leaveAt == nil { leaveAt = now }
            if now - leaveAt! >= Self.grace - 1e-9 { lifted = nil; leaveAt = nil }
            return
        }
        leaveAt = nil
        if h == lifted { cand = nil; return }
        if cand != h { cand = h; candAt = now }
        if now - candAt >= Self.dwell - 1e-9 { lifted = h; cand = nil }
    }
    /// 點了一顆、或在某顆裡打字：浮起取消（那顆改由 pinned 留在上面）；滑鼠不移到別處就不再浮
    public mutating func settle(hover: String?) { self = HoverLift(); mute = .some(hover) }
    /// 視窗不在了
    public mutating func drop(_ id: String) { if lifted == id { lifted = nil }; if cand == id { cand = nil } }
}
