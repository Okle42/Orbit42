import Foundation

/// cool42 狀態
public struct CoolState: Sendable, Equatable {
    public var temp: Double?
    public var cpuAvg: Double?
    public var level: String?        // ok／warm／hot／critical
    public var stale = false         // 狀態檔超過 2 分鐘沒更新
    public init(temp: Double? = nil, cpuAvg: Double? = nil, level: String? = nil, stale: Bool = false) {
        self.temp = temp; self.cpuAvg = cpuAvg; self.level = level; self.stale = stale
    }
    public var known: Bool { temp != nil && !stale }
    public var alert: Bool { known && (level == "hot" || level == "critical") }
}

public enum CoolParse {
    /// cool42 /var/run/cool42/state.json：controlTemp、cpuAvg、level、time（超過 2 分鐘沒更新＝stale）
    public static func cool42(_ d: Data?, now: Date) -> CoolState {
        guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return CoolState() }
        var p = CoolState(temp: (o["controlTemp"] as? NSNumber)?.doubleValue, cpuAvg: (o["cpuAvg"] as? NSNumber)?.doubleValue, level: o["level"] as? String)
        if let t = o["time"] as? String, let at = ISO8601DateFormatter().date(from: t) { p.stale = now.timeIntervalSince(at) > 120 }
        return p
    }
}
