import Darwin
import Foundation

/// 改資料位置的環境變數只有測試版（DEBUG）吃；正式版一律用系統帳號的家目錄（防冒充方案 A：不能帶變數把檢查指到別的資料夾）
public enum TestEnv {
    public static func path(_ key: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[key]
        #else
        nil
        #endif
    }
    public static var home: URL {
        #if DEBUG
        FileManager.default.homeDirectoryForCurrentUser
        #else
        getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
        #endif
    }
}
