import Foundation
import Testing

/// 測試跑外部指令。不用 Process：
/// ① Process 沒指定 environment 就直接拿行程當下的 environ，別的測試同時 setenv 會讓它搬家 ⇒ 啟動失敗 EFAULT（11-25 抓到 "Bad address"）
/// ② 平行跑時 waitUntilExit 偶爾等不到已經結束的子程序
enum Spawn {
    /// 第一次用到時拍一份，之後都用這份
    static let env: [String] = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SHOWORK_") }.map { "\($0.key)=\($0.value)" }

    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { Issue.record("pipe errno \(errno)"); return (127, "") }
        var fa: posix_spawn_file_actions_t?, at: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&at)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&at) }
        posix_spawnattr_setflags(&at, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))      // 別的子程序不會繼承這條管線
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var av: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil], ev: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer { av.forEach { free($0) }; ev.forEach { free($0) } }
        var pid: pid_t = 0
        let e = posix_spawn(&pid, exe, &fa, &at, &av, &ev)
        close(fds[1])
        let h = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        guard e == 0 else { Issue.record("\(exe) 開不起來：\(String(cString: strerror(e)))"); return (127, "") }
        let d = h.readDataToEndOfFile()
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
        return (st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f), String(decoding: d, as: UTF8.self))
    }
}
