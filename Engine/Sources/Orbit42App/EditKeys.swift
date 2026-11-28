import Foundation

// 11-28 Keng「衛星終端機裡複製貼上還是不能用」：⌘C／⌘V 走主選單送給「目前的焦點」；焦點不在終端機上（被球體拿走、
// 掉回視窗本身⋯⋯不管怎麼丟的），選單就是灰的，按了沒反應。⇒ 按下去那一刻：目前的焦點接不住這個動作，就把焦點交給
// 滑鼠底下那顆衛星（不在任何一顆上就給浮著那顆），再照常送出。焦點接得住（網址列、答案卡、選了字的網頁）就完全不動。
public enum EditKeys {
    /// ⌘ 加哪個實體鍵 ⇒ 哪個編輯動作（用按鍵碼：注音等輸入法開著時字元會變）。只認單獨 ⌘（⌃⌥⇧ 都不算）
    public static func action(keyCode: UInt16, command: Bool, others: Bool) -> String? {
        guard command, !others else { return nil }
        return [8: "copy:", 9: "paste:", 7: "cut:", 0: "selectAll:"][keyCode]
    }
    /// 要把焦點交給哪顆（nil＝不動）：
    /// 焦點在某顆衛星裡、或在答案卡 ⇒ 那是使用者選的，不動
    /// 焦點在衛星外（球體、視窗本身）而滑鼠在某顆衛星上 ⇒ 給那顆（人看著那顆終端機按 ⌘V）
    /// 滑鼠不在衛星上 ⇒ 只有目前焦點接不住這個動作（選單反灰）時，才給浮著的那顆
    public static func route(focus: HoverLift.Focus, canPerform: Bool, hover: String?, lifted: String?, shown: Set<String>) -> String? {
        switch focus { case .sat, .ask: return nil; case .nowhere, .elsewhere: break }
        if let h = hover, shown.contains(h) { return h }
        if !canPerform, let l = lifted, shown.contains(l) { return l }
        return nil
    }
    /// 診斷紀錄（只記 ⌘C／⌘X／⌘V／⌘A）：~/Library/Logs/Orbit42/editkeys.log，超過 200KB 從頭寫
    @MainActor public static func log(_ line: String, file: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Orbit42/editkeys.log")) {
        if AppTest.mode { print("editkeys \(line)"); return }          // 測試不寫正式的紀錄檔
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
        let d = Data("\(f.string(from: Date())) \(line)\n".utf8), fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let big = ((try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0) ?? 0 > 200_000
        if !big, let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: file) }
    }
}
