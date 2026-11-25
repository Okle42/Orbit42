import Foundation

/// 11-25 Keng「截圖放在系統不給讀的暫存區，修好，我要你讀得到」：
/// macOS 截圖縮圖拖進來的是系統暫存區（…/T/TemporaryItems/NSIRD_screencaptureui_*）的檔。拖放那一刻 Orbit42 讀得到，
/// 終端機裡的 AI 是另一個程序、沒有權限（EPERM），檔案過一會也會被系統收走 ⇒ 當場複製一份，貼複本的路徑。
/// 其他位置的檔案照舊貼原路徑（改到的是原檔）。複製失敗也照舊。
enum DropCopy {
    static var dir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Orbit42/drops", isDirectory: true) }
    static func isTemporary(_ u: URL) -> Bool {
        let p = u.standardizedFileURL.path
        return p.contains("/TemporaryItems/") && (p.hasPrefix("/var/folders/") || p.hasPrefix("/private/var/folders/"))
    }
    /// 檔名：日期時間＋原名，空白換底線（貼進終端機不用跳脫）
    static func name(_ u: URL, now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: now) + "-" + u.lastPathComponent.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
    }
    static func readable(_ u: URL, into d: URL = dir, now: Date = Date()) -> URL {
        guard isTemporary(u), (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return u }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let base = d.appendingPathComponent(name(u, now: now)), ext = base.pathExtension, stem = base.deletingPathExtension().lastPathComponent
            var to = base, n = 2
            while fm.fileExists(atPath: to.path) { to = d.appendingPathComponent("\(stem)-\(n)" + (ext.isEmpty ? "" : "." + ext)); n += 1 }
            try Data(contentsOf: u).write(to: to, options: [.withoutOverwriting])      // 重寫一份：不帶原檔的延伸屬性與限制
            return to
        } catch { NSLog("drop copy failed: \(error.localizedDescription)"); return u }
    }
}
