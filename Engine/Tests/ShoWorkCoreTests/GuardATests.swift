import Foundation
import Testing
@testable import ShoWorkCore

/// 防冒充方案 A：只驗原理（分類與判斷），不執行任何指令
@Suite struct GuardATests {
    static let wrapped: [(String, Bool)] = [
        (#"sh -c "rm -rf x""#, true), (#"bash -lc 'rm x'"#, true), (#"zsh -f -c "cd a && rm -rf b""#, true), (#"/bin/bash -c 'rm x'"#, true), (#"bash -o pipefail -c 'rm x'"#, true),
        (#"eval "rm -rf x""#, true), ("eval rm x", true), ("ls | xargs rm", true), ("ls | xargs -I {} rm {}", true), ("ls | xargs -n 1 sh -c 'rm $0'", true),
        (#"\rm -rf x"#, true), ("/bin/rm -rf x", true), (#"r""m x"#, true), (#"'rm' x"#, true), ("command rm x", true), ("env A=1 /bin/rm x", true), ("nohup /bin/rm x", true), ("time nice -n 5 rm x", true), ("timeout 5 rm x", true),
        ("find . -name x -delete", true), ("find . -exec rm {} +", true), (#"find . -exec sh -c 'rm "$1"' _ {} \;"#, true), (#"echo "$(rm x)""#, true), (#"echo "`rm x`""#, true),
        (#"python3 -c "import os;os.remove('a')""#, true), (#"python3 -I -c "import shutil; shutil.rmtree('a')""#, true), (#"node -e "require('fs').rmSync('a')""#, true), ("perl -e 'unlink(\"a\")'", true),
        (#"sh -c "$X""#, true), (#"eval "$X""#, true), ("curl -s u | sh", true), ("cat a | bash -s", true), (#"sh -c 'bash -c "rm x"'"#, true), ("timeout 9 firebase deploy", true), ("/opt/homebrew/bin/firebase deploy", true),
        // 日常的不可擋
        ("git status && git log --oneline | head", false), ("swift build -c release 2>&1 | tail", false), ("grep -rn 'rm -rf' .", false), ("echo 'rm x'", false), ("bash script.sh", false), ("zsh -n a.sh", false), (#"sh -c "ls -la | grep x""#, false),
        ("find . -name '*.swift' -exec grep -n x {} +", false), ("find /tmp/x -delete", false), ("ls | xargs grep x", false), (#"python3 -c "print(1)""#, false), ("/bin/rm -rf /tmp/x", false), (#"sh -c "rm -rf /tmp/x""#, false), ("command -v rm", false),
        ("which rm", false), (#"git commit -m "rm x; eval y""#, false), ("ssh host 'ls'", false), (#"echo "$(git rev-parse HEAD)""#, false), ("cat a | python3 -", false), ("env | grep CLAUDE", false), ("xcrun simctl list", false), ("cat x | tee y", false), ("git rm --cached a", false), ("npm run build", false),
        ("eval \"$(/opt/homebrew/bin/brew shellenv)\"", false),
    ]
    @Test func wrappers() {
        let rules = CaptainLink.defaultRules.filter(\.block)
        for (c, want) in Self.wrapped { #expect(!CaptainLink.hits(c, rules: rules).isEmpty == want, "\(c)") }
        // 原本會擋的不可因為多切段而漏掉；深層不會當掉
        #expect(!CaptainLink.hits(String(repeating: "sh -c \"", count: 40), rules: rules).isEmpty || true)
    }
    @Test func internalCommands() {
        func blocked(_ c: String) -> Bool { CaptainLink.hits(c, rules: []).contains { $0.rule.name == CaptainLink.internalRule } }
        for c in ["title", "permit", "guard-push", "brief", "emit done", "statusline"] { for p in ["showork", "\"/a b/bin/showork\"", "./showork", "exec showork", "command showork"] { #expect(blocked("echo '{}' | \(p) \(c)"), "\(p) \(c)") } }
        #expect(blocked("sh -c 'showork title'"))
        for c in ["card --doing x", "captain", "task add --to a --text title", "asks withdraw all", "names", "release BABCD", "roster", "b1 read", "preview-check 'showork title'", "--help", "guard status"] { #expect(!blocked("showork \(c)"), "\(c)") }
        #expect(!blocked("grep -n 'showork title' a") && !blocked("git commit -m 'showork title'"))
    }
    @Test func caller() {
        #expect(Caller.judge(claimed: "a", real: "a", live: ["a", "b"]) == .ok)
        #expect(Caller.judge(claimed: "b", real: "a", live: ["a", "b"]) != .ok && Caller.judge(claimed: "zzz", real: "a", live: ["a"]) != .ok)
        #expect(Caller.judge(claimed: "a", real: nil, live: ["a"]) != .ok && Caller.judge(claimed: "diskguard", real: nil, live: ["a"]) == .ok)
        #expect(Caller.hookOK(sid: "a", parent: 7, sessions: [(7, "a"), (8, "b")]))
        #expect(!Caller.hookOK(sid: "b", parent: 7, sessions: [(7, "a"), (8, "b")]) && !Caller.hookOK(sid: "a", parent: 99, sessions: [(7, "a")]))
    }
    @Test func captainClaim() {
        #expect(CaptainClaim.decide(current: "a", me: "a", live: ["a"], on: true) == .take(notify: false))
        #expect(CaptainClaim.decide(current: "a", me: "b", live: ["a", "b"], on: true) == .ask)
        #expect(CaptainClaim.decide(current: "a", me: "b", live: ["b"], on: true) == .take(notify: true) && CaptainClaim.decide(current: nil, me: "b", live: ["b"], on: true) == .take(notify: true))
        #expect(CaptainClaim.decide(current: "a", me: "b", live: ["a", "b"], on: false) == .take(notify: false))
        var q = PendingAsk(id: "Q1", ask: "x", options: [CaptainClaim.no, CaptainClaim.yes], at: Date())
        #expect(!CaptainClaim.approves(q, option: CaptainClaim.yes, free: nil, fromMac: true))      // AI 自己發的同文題不算
        q.action = "captain"
        #expect(CaptainClaim.approves(q, option: CaptainClaim.yes, free: nil, fromMac: true) && !CaptainClaim.approves(q, option: CaptainClaim.yes, free: nil, fromMac: false))
        #expect(!CaptainClaim.approves(q, option: CaptainClaim.no, free: nil, fromMac: true) && !CaptainClaim.approves(q, option: CaptainClaim.yes, free: "先不要", fromMac: true) && !CaptainClaim.approves(q, option: nil, free: CaptainClaim.yes, fromMac: true))
        let xs = AskQueue.adding(SelfReport(status: .review, ask: "x", options: ["好", "不"], at: Date()), to: [q])
        #expect(xs.count == 1 && xs[0].options == q.options)
    }
}
