import Foundation

// 11-25 Keng：終端機滑過浮起（T1125035226）。純判斷，畫面在 Orbit42 的 main.swift。
// 11-28 起：滑進哪顆就立刻浮到最上、輸入點也換過去（Keng 改口，以 11-28 為準）。只決定「換誰」，不碰位置大小。

/// 滑鼠速度（點／秒）：看最近 0.06 秒內移了多遠；超過 0.03 秒沒動就算停下來
public struct MouseSpeed: Sendable {
    public static let span = 0.06, still = 0.03, fast = 500.0
    private var pts: [(t: Double, p: CGPoint)] = []
    public init() {}
    public mutating func add(_ t: Double, _ p: CGPoint) { pts.append((t, p)); pts.removeAll { t - $0.t > Self.span } }
    public func speed(_ now: Double) -> Double {
        guard let b = pts.last, now - b.t <= Self.still, let a = pts.first(where: { now - $0.t <= Self.span }), b.t > a.t else { return 0 }
        return hypot(b.p.x - a.p.x, b.p.y - a.p.y) / (b.t - a.t)
    }
    public func isFast(_ now: Double) -> Bool { speed(now) > Self.fast }
}

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
    /// 11-28 Keng「視窗大小可以再大一點，只要我方便切換視窗就行」→ 同日改「原本的縮小一點點，選到的浮上來放大一點點」：
    /// 多顆斜對角排開時每顆的大小（不含 420×260 下限）。最多 寬 74%、高 82%（留空間給選到的那顆放大 3%）；越多顆越小，保證每顆往右下錯開至少 44 × (標題列＋4) ⇒ 每條標題列完整露出、滑鼠瞄得到
    public static let minStep = CGSize(width: 44, height: 4)
    public static func size(count n: Int, area: CGSize, bar: CGFloat) -> (CGFloat, CGFloat) {
        guard n > 1 else { return (area.width, area.height) }
        let k = CGFloat(n - 1)
        return (min(area.width * 0.74, area.width - k * minStep.width), min(area.height * 0.82, area.height - k * (bar + minStep.height)))
    }
    /// 選到的那顆（滑過／搖桿／點的）要不要放大：它在最上面、還開著，而且不只一顆（只有一顆時放大沒意義）
    public static func raised(pinned: String?, shown: Set<String>) -> String? {
        guard let p = pinned, shown.contains(p), shown.count > 1 else { return nil }
        return p
    }
    /// 浮起時誰要變暗：浮起那顆和正在打字那顆以外
    public static func dimmed(_ order: [String], lifted: String?, typing: String?) -> Set<String> {
        guard let l = lifted else { return [] }
        return Set(order).subtracting([l]).subtracting(typing.map { [$0] } ?? [])
    }
}

/// 11-28 Keng「滑鼠移過去要立刻反應，滑過去輸入點就在那個視窗上」：滑進哪顆就立刻換它（浮到最上＋拿輸入點），不等、不用點。
/// 離開所有衛星（球體、空白、答案卡）不歸位：輸入點留在最後那顆。拖曳、選單、組字中不換。
public struct HoverLift: Equatable, Sendable {
    /// 最後滑進（或點過、打字）的那顆：畫在最上面、鍵盤輸入點在它身上
    public private(set) var lifted: String?
    private var mute: String??                // 輸入點被別的方式換走（開新衛星、在別顆打字）時滑鼠停在這顆：要先移到別處才會換
    public init() {}
    /// hover＝滑鼠底下那顆（nil＝空白處）；inside＝滑鼠在 Orbit42 視窗裡而且視窗有焦點；paused＝拖曳、捲動、組字、選單開著⋯
    /// 回傳：這一步要換過去（浮起＋聚焦）的那顆；nil＝不用動
    /// fast＝滑鼠正在快速移動（11-28 Keng：快速掃過別顆不換，停下或慢下來才換 ⇒ 移向某顆的叉叉時不會被路過的那顆蓋住）
    @discardableResult
    public mutating func step(hover: String?, inside: Bool, paused: Bool, fast: Bool = false) -> String? {
        guard inside, !paused else { return nil }                       // 離開視窗、失焦、凍結：什麼都不動（輸入點留著）
        if let m = mute { if m == hover { return nil }; mute = nil }
        guard let h = hover, h != lifted else { return nil }            // 空白處：留在最後那顆
        if fast { return nil }                                          // 路過：先不換（停下來會再看一次）
        lifted = h
        return h
    }
    /// 輸入點已經在 id 上（點了、在裡面打字、程式開新衛星）；滑鼠停在 hover：沒移出 hover 之前不搶回去
    public mutating func settle(_ id: String?, hover: String?) { lifted = id; mute = hover == id ? nil : .some(hover) }
    /// 視窗不在了
    public mutating func drop(_ id: String) { if lifted == id { lifted = nil }; if mute == .some(id) { mute = nil } }
}
