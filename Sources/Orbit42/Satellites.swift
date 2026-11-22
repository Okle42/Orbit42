import Foundation
import ShoWorkCore

/// Which AI runs inside a satellite. Each brain is the vendor's own official CLI agent,
/// so login, tools and updates stay theirs (S2 turns this into a full adapter: status, resume, usage).
enum Brain: String, CaseIterable, Sendable {
    case claude, codex, gemini
    var label: String { ["claude": "Claude", "codex": "ChatGPT", "gemini": "Gemini"][rawValue]! }
    var command: String { ["claude": "claude", "codex": "codex", "gemini": "agy"][rawValue]! }   // Gemini 走 Antigravity CLI（2026-05 起取代 Gemini CLI）
}

/// One AI worker on the sphere: a terminal (PTY) plus what it is running.
final class Satellite: @unchecked Sendable {
    let id: String
    var name: String
    let brain: Brain
    let cwd: String
    let command: String
    let attachedJob: String?          // background Claude session we attached to (not started by Orbit42)
    var pty: Pty?
    var exited: Int32?
    var lastOutput = Date.distantPast
    private(set) var scrollback = Data()     // replayed when the terminal panel is reopened
    private let lock = NSLock()

    init(id: String, name: String, brain: Brain, cwd: String, command: String, attachedJob: String? = nil) {
        self.id = id; self.name = name; self.brain = brain; self.cwd = cwd; self.command = command; self.attachedJob = attachedJob
    }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        scrollback.append(d)
        let cap = 2 * 1024 * 1024
        if scrollback.count > cap { scrollback.removeFirst(scrollback.count - cap) }
        lastOutput = Date()
    }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return scrollback }

    var json: [String: Any] {
        let state = exited != nil ? "exited" : pty == nil ? "idle" : Date().timeIntervalSince(lastOutput) < 3 ? "busy" : "open"
        var o: [String: Any] = ["id": id, "name": name, "brain": brain.rawValue, "brainLabel": brain.label, "cwd": cwd, "state": state]
        if let j = attachedJob { o["job"] = j }
        if let e = exited { o["exit"] = e }
        return o
    }
}

/// Background Claude sessions that can be pulled in as satellites (`claude attach <job>`).
enum BackgroundSessions {
    static func list() -> [[String: Any]] {
        let fm = FileManager.default, dir = NSHomeDirectory() + "/.claude/sessions"
        let recs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { f -> SessionRecord? in
            guard let d = fm.contents(atPath: dir + "/" + f), let r = SessionRecord.decode(d), kill(r.pid, 0) == 0 else { return nil }
            return r
        }
        return recs.filter { $0.kind == "bg" && $0.jobId != nil && ($0.name ?? "").isEmpty == false && $0.name != String($0.sessionId.prefix(8)) }
            .map { ["job": $0.jobId!, "name": $0.name ?? $0.jobId!, "cwd": $0.cwd, "status": $0.status ?? "?"] }
    }
}
