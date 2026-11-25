import Foundation

/// 系統通知與 AppleScript 字串：只有這一份
enum Notify {
    static func quote(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    /// 會等 osascript 結束，呼叫端自己決定要不要丟背景
    static func sendNow(_ title: String, _ body: String) {
        let f = { (s: String) in quote(s).replacingOccurrences(of: "\n", with: " ") }
        Tools.run("/usr/bin/osascript", ["-e", "display notification \"\(f(body))\" with title \"Orbit42\" subtitle \"\(f(title))\""], timeout: 10)
    }
    static func send(_ title: String, _ body: String) { DispatchQueue.global().async { sendNow(title, body) } }
}
