import CryptoKit
import Foundation

/// 暫時關掉防冒充檢查：只能在 Orbit42 選單按、經系統驗證（Touch ID 或 Mac 密碼）才簽得出來，最多 30 分鐘、到時自動恢復。
/// 簽章鑰匙在安全晶片裡、每次用都要系統驗證。同帳號的程式若連公鑰檔一起換掉，這裡擋不住（方案 B 再鎖）。
public struct GuardOff: Codable, Sendable, Equatable {
    public var until: Date, sig: Data
    public init(until: Date, sig: Data) { self.until = until; self.sig = sig }
    public static let limit: TimeInterval = 30 * 60
    public static var dir: URL {
        if let p = ProcessInfo.processInfo.environment["SHOWORK_GUARD_DIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        return Captain.dir.appendingPathComponent("guard", isDirectory: true)
    }
    public static var file: URL { dir.appendingPathComponent("a-off.json") }
    public static var keyFile: URL { dir.appendingPathComponent("a-off.pub") }

    public static func message(_ until: Date) -> Data { Data("orbit42-guard-off|\(Int(until.timeIntervalSince1970))".utf8) }
    /// 純判斷：簽章對、還沒到期、沒有超過上限
    public static func valid(_ o: GuardOff, key: Data, now: Date) -> Bool {
        guard o.until > now, o.until.timeIntervalSince(now) <= limit, let k = try? P256.Signing.PublicKey(x963Representation: key),
              let s = try? P256.Signing.ECDSASignature(derRepresentation: o.sig) else { return false }
        return k.isValidSignature(s, for: message(o.until))
    }
    public static func active(now: Date) -> Bool { current(now: now) != nil }
    public static func current(now: Date) -> GuardOff? {
        guard let d = FileManager.default.contents(atPath: file.path), let o = try? JSONDecoder().decode(GuardOff.self, from: d),
              let k = FileManager.default.contents(atPath: keyFile.path), valid(o, key: k, now: now) else { return nil }
        return o
    }
    public static func save(_ o: GuardOff, key: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try key.write(to: keyFile, options: .atomic)
        try JSONEncoder().encode(o).write(to: file, options: .atomic)
    }
}
