import Foundation
import Darwin


/// One pseudo-terminal running one command (a satellite's terminal).
/// Output arrives on a background queue via `onData`; `onExit` fires once when the child ends.
final class Pty: @unchecked Sendable {
    let pid: pid_t
    let fd: Int32
    private var source: DispatchSourceRead?
    private let q = DispatchQueue(label: "orbit42.pty")
    var onData: (Data) -> Void = { _ in }
    var onExit: (Int32) -> Void = { _ in }

    /// Runs `command` through the user's login zsh (so PATH, nvm, etc. match a normal terminal).
    init?(command: String, cwd: String, cols: Int, rows: Int, env extra: [String: String] = [:]) {
        // Build argv/envp before fork: the child may only call async-signal-safe functions.
        var env = ProcessInfo.processInfo.environment
        // Don't leak the launching agent's session markers (e.g. Orbit42 started from inside Claude Code):
        // the satellite must be its own fresh session, with transcripts saved normally.
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDE_JOB_DIR" || k.hasPrefix("CLAUDE_SESSION") { env[k] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Orbit42"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        for (k, v) in extra { env[k] = v }
        let shell = "/bin/zsh"
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-l"), strdup("-c"), strdup(command), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let dir = strdup(cwd)
        defer { argv.forEach { free($0) }; envp.forEach { free($0) }; free(dir) }

        var win = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &win)
        if child < 0 { return nil }
        if child == 0 {
            _ = chdir(dir)
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    _ = execve(shell, a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        pid = child
        fd = master
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { onData(Data(buf[0..<n])); continue }
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { finish(); return }
            return
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        source?.cancel(); source = nil
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        onExit(status)
        Self.release(self)
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n > 0 { off += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { return }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        var win = winsize(ws_row: UInt16(max(rows, 2)), ws_col: UInt16(max(cols, 10)), ws_xpixel: 0, ws_ypixel: 0)
        // 11-23 修：之前用 @_silgen_name 自己宣告 ioctl（非可變參數），在 Apple 晶片上可變參數走堆疊、不走暫存器
        // ⇒ 指標傳錯、改尺寸從來沒成功，程式收不到 SIGWINCH，調視窗大小後畫面整片錯位。改用 Darwin 內建的 ioctl 包裝
        _ = ioctl(fd, UInt(TIOCSWINSZ), &win)
    }

    /// Hang up: the shell and its children get SIGHUP like when a terminal window closes.
    /// 11-23 Keng「關掉以後它還在，點了說找不到 session 的視窗」：之前送完 SIGHUP 衛星就被丟掉、這個物件跟著消失，
    /// 沒人再讀終端機 ⇒ 程序結束時要等輸出被讀完、永遠卡在「正在結束」（ps 狀態 E），session 一直算活著；
    /// 順利結束的也沒人 waitpid ⇒ 殭屍程序。現在掛斷後自己撐到程序真的結束：繼續把輸出讀掉（丟掉）、回收程序；
    /// 8 秒還沒結束就 SIGKILL
    func hangup() {
        onData = { _ in }
        Self.retain(self)
        kill(pid, SIGHUP)
        q.asyncAfter(deadline: .now() + 8) { [self] in if !finished { kill(pid, SIGKILL) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var closing: [ObjectIdentifier: Pty] = [:]
    private static func retain(_ p: Pty) { lock.lock(); closing[ObjectIdentifier(p)] = p; lock.unlock() }
    private static func release(_ p: Pty) { lock.lock(); closing[ObjectIdentifier(p)] = nil; lock.unlock() }
}
