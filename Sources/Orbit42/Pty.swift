import Foundation
import Darwin

// ioctl is variadic in C and not imported into Swift; declare the one shape we need (window size).
@_silgen_name("ioctl") private func ioctl_ptr(_ fd: Int32, _ request: UInt, _ ptr: UnsafeMutableRawPointer) -> Int32

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
        _ = ioctl_ptr(fd, UInt(TIOCSWINSZ), &win)
    }

    /// Hang up: the shell and its children get SIGHUP like when a terminal window closes.
    func hangup() { kill(pid, SIGHUP) }
}
