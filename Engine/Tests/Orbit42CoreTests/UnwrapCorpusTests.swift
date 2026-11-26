import Foundation
import Testing
@testable import Orbit42Core

@Suite struct UnwrapCorpusTests {
    /// 近 30 天真指令（唯讀，環境變數給檔）：新增擋下的列成類型
    @Test func corpus() throws {
        guard let p = ProcessInfo.processInfo.environment["GUARD_CORPUS"], let d = FileManager.default.contents(atPath: p) else { return }
        let xs = try JSONDecoder().decode([String].self, from: d), rules = CaptainLink.defaultRules.filter(\.block)
        var added: [String: Int] = [:], lost = 0, old = 0
        for c in xs {
            let plain = CaptainLink.rawSegments(c).filter { !CaptainLink.isOrbit($0) }.map { $0.hasPrefix("ssh ") ? $0 : CaptainLink.blankQuotes($0) }
            func hit(_ r: CaptainLink.Rule) -> Bool { guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]) else { return false }; return plain.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } }
            let a = Set(rules.filter(hit).map(\.name)), hs = CaptainLink.hits(c, rules: rules), b = Set(hs.map(\.rule.name))
            if !a.isEmpty { old += 1 }
            if !a.isSubset(of: b) { lost += 1; print("LOST", c.prefix(100)) }
            if a.isEmpty, !b.isEmpty { for n in b { added[n, default: 0] += 1 }; print("ADD", b.sorted(), "|", hs[0].segment.prefix(150).replacingOccurrences(of: "\n", with: "⏎")) }
        }
        print("CORPUS \(xs.count) 舊擋 \(old) 少擋 \(lost) 新增 \(added)")
    }
}
