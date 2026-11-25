import Foundation

/// 看板欄位換成人看得懂的狀態
public enum Mood: String, Sendable, CaseIterable {
    case working    // 進行中：紫光圈、打字
    case waiting    // 等你回答／AI 要你決定：紅「!」、跳
    case finished   // 做完了你還沒看：綠勾、搖擺
    case stuck      // 卡住：橘「?」
    case idle       // 做完你也看過了：沒有光圈、喝咖啡休息（10-15 Kang：跟「從來沒用過」分開）
    case asleep     // 開了 claude 但從來沒交代過事：閉眼、頭上 Zzz

    public static func of(_ c: BoardCard) -> Mood {
        switch c.column {
        case .active: .working
        case .review: c.reason == "等你回答" || c.reason.hasPrefix("要你決定") ? .waiting : .finished
        case .stuck: .stuck
        case .done, .todo: c.unused ? .asleep : .idle
        }
    }
}
