import Foundation

/// 測試模式（11-26 從 BoardWindow.testMode 搬來）：螢幕外、不准開到使用者螢幕、不准真的動手（不送、不寫檔、不掃網路）。
/// Orbit42 的 ORBIT_OFFSCREEN／AgentOptions.testOnly 會打開它。
@MainActor
public enum AppTest {
    public static var mode = false
}
