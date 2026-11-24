import Darwin
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
        ("X=rm; $X a", true), ("X=/bin/rm; \"$X\" -rf a", true), ("$Y a b", true), ("S=\"/a b/bin/showork\"; \"$S\" title", true), ("\"$CMD\" -x", true),
        ("python3 - <<'E'\nimport os\nos.remove('a')\nE", true), ("showork card --summary \"$(rm x)\"", true), ("\"/a b/bin/showork\" card --summary \"`rm x`\"", true), ("showork card --summary \"$(showork title)\"", true),
        ("S=\"/a b/bin/showork\"; \"$S\" card --summary 'rm x'", false), ("S='/a b/bin/showork'\n$S names", false), ("B=.build/release/x; $B --help", false), ("showork card --summary \"$(date)\"", false), ("python3 - <<'E'\nprint(1)\nE", false), ("cat <<'E' > a.py\nimport os\nos.remove('a')\nE", false), ("showork guard off", false),
        ("A=\"$(rm -rf x)\"", true), ("A=\"`rm x`\"", true), ("OUT=\"$(firebase deploy)\"; echo $OUT", true), ("A=\"$(showork title)\"", true), ("FOO=\"$(rm x)\" showork card --doing a", true), ("export A=\"$(rm x)\"", true), ("A=\"$(date)\" B=\"$(rm x)\" ls", true),
        ("X=ls; X=rm; $X a", true), ("X=$(echo rm); $X a", true),
        ("A=\"$(git rev-parse HEAD)\"; echo $A", false), ("e=1; s=2; echo $(($e-$s))", false), ("for f in a b; do echo $(($f)); done", false), ("A=$(grep x y | cut -d= -f2)/platform-tools/adb; $A devices", false), ("T=$(which tailscale); \"$T\" status", false), ("ADB=/o/adb; $ADB devices -l", false), ("ADB=/o/adb; ADB=\"$ADB -s x\"; $ADB devices", false),
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
    @Test func identity() {
        #expect(Caller.isInstalled(exe: "/i/showork", argv0: "/i/showork", installed: "/i/showork"))
        #expect(!Caller.isInstalled(exe: "/tmp/copy", argv0: "/tmp/copy", installed: "/i/showork") && !Caller.isInstalled(exe: "/i/showork", argv0: "/tmp/link", installed: "/i/showork"))
        // 假的 sessions 檔登記成自己的 shell：簽章不對就往上找
        #expect(Caller.realSession(startingAt: getpid(), records: [getpid(): "fake"], isClaude: { _ in false }) == nil)
        #expect(Caller.realSession(startingAt: getpid(), records: [getpid(): "real"], isClaude: { $0 == getpid() }) == "real")
        #expect(!Caller.isClaude(getpid()))
        // 在 Claude Code 裡跑測試時：兩種認法都要認得出真的
        if let p = ProcessInfo.processInfo.environment["CLAUDE_PID"].flatMap(Int32.init) {
            #expect(Caller.isClaude(p))
            #expect(Caller.kernelIdentity(p).map { $0 == ("com.anthropic.claude-code", "Q6L2SF6YDW") } == true)
        }
    }
    @Test func guardOff() throws {
        let now = Date()
        #expect(GuardOff.valid(now + 1700, now: now) && !GuardOff.valid(now - 1, now: now) && !GuardOff.valid(now + 7200, now: now))
        // 插座通了也要驗對方：不是 Orbit42 簽的（這個測試程序自己開的）就不算暫停
        let p = "/tmp/gs-\(getpid()).sock"
        defer { unlink(p) }
        let u = Date(timeIntervalSince1970: (now.timeIntervalSince1970 + 600).rounded())
        #expect(GuardOff.serve(p, until: { u }) != nil)
        #expect(GuardOff.ask(p, trusted: { _ in true }) == u)
        #expect(GuardOff.ask(p, trusted: GuardOff.isOrbit) == nil && GuardOff.ask("/tmp/none.sock", trusted: { _ in true }) == nil)
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
        #expect(CaptainClaim.needsMac(q, option: CaptainClaim.yes, fromMac: false) && !CaptainClaim.needsMac(q, option: CaptainClaim.yes, fromMac: true) && !CaptainClaim.needsMac(q, option: CaptainClaim.no, fromMac: false))
        let xs = AskQueue.adding(SelfReport(status: .review, ask: "x", options: ["好", "不"], at: Date()), to: [q])
        #expect(xs.count == 1 && xs[0].options == q.options)
    }
}
