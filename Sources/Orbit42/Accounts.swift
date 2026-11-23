import Foundation

/// Which AI provider accounts this Mac is signed in to. Orbit42 never stores credentials:
/// it only asks each provider's own CLI (or reads the CLI's own "who is signed in" file) and,
/// to sign in, runs that CLI's official login in a terminal.
struct Provider: Sendable {
    let id: String            // claude / codex / gemini / grok
    let name: String          // what the user sees
    let company: String
    let cli: String           // command that must exist on PATH
    let login: String?        // command that runs the provider's official sign-in
    let install: String?      // how to install the CLI (shown, run only when the user presses it)
    var installed = false
    var signedIn = false
    var account: String?      // e-mail / plan, shown only on this screen
    var plan: String?
    var available = true      // false = not supported yet

    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "name": name, "company": company, "installed": installed, "signedIn": signedIn, "available": available]
        if let a = account { o["account"] = a }
        if let p = plan { o["plan"] = p }
        if let l = login { o["login"] = l }
        if let i = install { o["install"] = i }
        return o
    }
}

enum Accounts {
    static let all: [Provider] = [
        Provider(id: "claude", name: "Claude", company: "Anthropic", cli: "claude", login: "claude auth login",
                 install: "curl -fsSL https://claude.ai/install.sh | bash"),
        Provider(id: "codex", name: "ChatGPT", company: "OpenAI", cli: "codex", login: "codex login",
                 install: "npm install -g @openai/codex"),
        // Antigravity CLI (replaced Gemini CLI in 2026-05) has no separate login command: the first run signs in with Google
        Provider(id: "gemini", name: "Gemini", company: "Google", cli: "agy", login: "agy", install: nil),
        Provider(id: "grok", name: "Grok", company: "xAI", cli: "grok", login: nil, install: nil, available: false),
    ]

    /// Runs in the background; a few login-shell lookups, nothing is changed.
    static func check() -> [Provider] {
        let home = NSHomeDirectory()
        return all.map { p0 in
            var p = p0
            guard p.available else { return p }
            p.installed = !(shell("command -v \(p.cli)").isEmpty)
            guard p.installed else { return p }
            switch p.id {
            case "claude":
                if let d = shell("claude auth status --json").data(using: .utf8),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    p.signedIn = j["loggedIn"] as? Bool ?? false
                    p.account = j["email"] as? String
                    p.plan = (j["subscriptionType"] as? String).map { $0.capitalized }
                }
            case "gemini":
                if let d = FileManager.default.contents(atPath: home + "/.gemini/google_accounts.json"),
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = j["active"] as? String, !a.isEmpty {
                    p.signedIn = true; p.account = a
                }
            case "codex":
                p.signedIn = FileManager.default.fileExists(atPath: home + "/.codex/auth.json")
            default: break
            }
            return p
        }
    }

    /// `zsh -lc` so PATH matches the user's normal terminal (nvm, ~/.local/bin…)
    static func shell(_ cmd: String) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        p.environment = env
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
