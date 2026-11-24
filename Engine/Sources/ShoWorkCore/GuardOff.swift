import Darwin
import Foundation
import Security

/// 暫時關掉防冒充檢查：狀態只在 Orbit42 的記憶體裡（Touch ID／Mac 密碼過了才設，最多 30 分鐘；App 關掉就恢復）。
/// showork 連 Orbit42 的插座問，並用核心給的對方身分驗它真的是 Keng 簽的 Orbit42；沒有任何檔案或環境變數能改。
public enum GuardOff {
    public static let limit: TimeInterval = 30 * 60
    static let requirement = #"identifier "ai.okle42.orbit42" and anchor apple generic and certificate leaf[subject.OU] = J79PXNQ765"#
    public static var socketPath: String { Paths.supportDir.appendingPathComponent("guard.sock").path }
    /// App 自己用：現在暫停到幾點
    nonisolated(unsafe) public static var local: (() -> Date?)?
    /// 純判斷：沒過期、沒超過上限
    static func valid(_ until: Date, now: Date) -> Bool { until > now && until.timeIntervalSince(now) <= limit }
    public static func current(now: Date = Date()) -> Date? {
        guard let u = local.map({ $0() }) ?? asked, valid(u, now: now) else { return nil }
        return u
    }
    private static let asked: Date? = ask(socketPath, trusted: isOrbit)

    static func address(_ path: String) -> sockaddr_un? {
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &a.sun_path) { b in path.utf8.enumerated().forEach { b[$0.offset] = $0.element } }
        return a
    }
    static func ask(_ path: String, trusted: (Int32) -> Bool) -> Date? {
        guard var a = address(path), case let fd = socket(AF_UNIX, SOCK_STREAM, 0), fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 400_000), on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, trusted(fd) else { return nil }
        var b = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &b, b.count)
        return n > 0 ? Double(String(decoding: b.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).map { Date(timeIntervalSince1970: $0) } : nil
    }
    /// 插座另一頭是不是 Keng 簽的 Orbit42（核心給的 audit token，不看名字）
    static func isOrbit(_ fd: Int32) -> Bool {
        var t = audit_token_t(), n = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &t, &n) == 0 else { return false }
        let d = withUnsafeBytes(of: &t) { Data($0) }
        var code: SecCode?, req: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: d] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
    /// App 端：有人連就回到期時間（沒暫停回 0）
    public static func serve(_ path: String = socketPath, until: @escaping @Sendable () -> Date?) -> Int32? {
        guard var a = address(path), case let fd = socket(AF_UNIX, SOCK_STREAM, 0), fd >= 0 else { return nil }
        unlink(path)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0, chmod(path, 0o600) == 0, listen(fd, 64) == 0 else { close(fd); return nil }
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let s = String(Int(until()?.timeIntervalSince1970 ?? 0))
                _ = s.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }
        return fd
    }
}
