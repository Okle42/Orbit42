import AppKit

// 編輯選單（10-25 Kang：「在戰情中心回答時沒法用語音輸入」）：agent 是 .accessory、從來沒設 mainMenu，
// 而 macOS 的「開始聽寫」（按兩下 Control）、⌘X／⌘C／⌘V／⌘A／⌘Z 都是掛在 App 的編輯選單上的快捷鍵——沒有選單就沒反應。
// 選單列不會出現（.accessory 沒有選單列），但快捷鍵照樣走 mainMenu；系統會自己在編輯選單尾端補「開始聽寫⋯」「表情與符號」。

@MainActor
public enum EditMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "關於Orbit42", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let set = app.addItem(withTitle: "設定⋯", action: #selector(MenuTarget.settings), keyEquivalent: ",")
        set.target = MenuTarget.shared; set.tag = settingsTag          // GuardPause、MacWindows 的項目插在這個前面
        app.addItem(.separator())
        app.addItem(withTitle: "隱藏Orbit42", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "隱藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "顯示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "結束Orbit42", action: #selector(MenuTarget.quit), keyEquivalent: "q").target = MenuTarget.shared
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編輯")
        edit.addItem(withTitle: "還原", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷貝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "視窗")
        win.addItem(withTitle: "收起最前面的衛星", action: #selector(MenuTarget.closeSat), keyEquivalent: "w").target = MenuTarget.shared
        win.addItem(withTitle: "縮到最小", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let full = win.addItem(withTitle: "全螢幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        winItem.submenu = win
        main.addItem(winItem)
        NSApplication.shared.mainMenu = main
    }

    static let settingsTag = 4201
    /// 宿主自己的項目：插在「設定⋯」前面
    public static func addAppItem(_ i: NSMenuItem) -> Bool {
        guard let m = NSApp.mainMenu?.items.first?.submenu, let at = m.items.firstIndex(where: { $0.tag == settingsTag }) else { return false }
        m.insertItem(i, at: at); return true
    }

    /// 測試用：編輯選單現在有哪些項目（含系統補上的）
    static func dump() -> [String] {
        NSApplication.shared.mainMenu?.items.dropFirst().first?.submenu?.items.map { $0.isSeparatorItem ? "—" : "\($0.title) [\($0.action.map(NSStringFromSelector) ?? "-")]" } ?? []
    }
}

/// 選單動作：⌘Q 先讓宿主確認（前景衛星會被關掉）；⌘W 只收起衛星，不關主視窗
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func settings() { SettingsPanel.shared.show() }
    @objc func quit() { if let c = SphereEmbed.command { c("quit") } else { NSApp.terminate(nil) } }
    @objc func closeSat() {
        if let w = NSApp.keyWindow, !(w.contentView is AskFloatRoot) { w.performClose(nil) } else { SphereEmbed.command?("closeSat") }
    }
}
