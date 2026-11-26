import AppKit
import SwiftUI
import Orbit42Core

// 11-26 拿掉看板視窗（BoardWindow）後，只在那個視窗有的操作搬到這裡（畫面不加常駐東西）：
//   衛星右鍵選單：放行、派工給它（含接力）、退回並補指示、丟回待辦、重新審核、拷貝 Session ID（同 BoardActions 那條路）
//   ＋ 新衛星 選單裡的「新任務⋯」：選資料夾、提示、全自動
// 表單開在一個小面板（測試模式開在螢幕外、什麼都不送）。

@MainActor
enum CardMenu {
    struct Item: Equatable { let title: String; let enabled: Bool }

    /// 這張卡的右鍵選單項目（順序、哪些能按）；跟 popUp 用同一份，測試也看這份
    static func items(_ c: BoardCard, reviewing: Set<String>) -> [Item] {
        var r: [Item] = []
        if c.column == .review { r.append(Item(title: "放行", enabled: true)) }
        if !c.captain { r.append(Item(title: "派工給它⋯", enabled: true)) }
        r.append(Item(title: "退回並補指示⋯", enabled: true))
        r.append(Item(title: "丟回待辦⋯", enabled: true))
        r.append(Item(title: "重新審核", enabled: !reviewing.contains(c.sessionId) && c.lastActivity != nil))
        r.append(Item(title: "-", enabled: false))
        r.append(Item(title: "拷貝 Session ID", enabled: true))
        return r
    }

    /// 在滑鼠位置彈出（view＝球體網頁）；tell：一句話回報（球體播報）
    static func popUp(_ c: BoardCard, in view: NSView, tell: @escaping @MainActor (String) -> Void) {
        let menu = NSMenu()
        let model = BoardModel.shared
        for it in items(c, reviewing: model.reviewing) {
            if it.title == "-" { menu.addItem(.separator()); continue }
            let mi = ActionItem(title: it.title) { run(it.title, c, tell: tell) }
            mi.isEnabled = it.enabled
            menu.addItem(mi)
        }
        menu.autoenablesItems = false
        guard let w = view.window else { return }
        let p = view.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: p, in: view)
    }

    /// 選了某一項（測試也直接叫這裡）
    static func run(_ title: String, _ c: BoardCard, tell: @escaping @MainActor (String) -> Void) {
        let model = BoardModel.shared
        switch title {
        case "放行":
            if AppTest.mode { return tell("測試：不放行「\(c.title)」") }
            BoardActions.approve(c); tell("已放行「\(c.title)」")
        case "派工給它⋯":
            let others = model.cards.filter { !$0.id.contains("#") && $0.sessionId != c.sessionId && !$0.captain }.compactMap(\.name)
            FormPanel.show("派工") { close in DispatchSheet(card: c, others: others, captain: model.cards.first { $0.captain }?.sessionId, onDone: tell, close: close) }
        case "退回並補指示⋯": FormPanel.show("退回") { close in SendBackSheet(card: c, onDone: tell, close: close) }
        case "丟回待辦⋯": FormPanel.show("丟回待辦") { close in ParkSheet(card: c, close: close) }
        case "重新審核":
            if AppTest.mode { return tell("測試：不審核") }
            Reviewer.shared.start(c, force: true)
        case "拷貝 Session ID":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.sessionId, forType: .string)
            tell("已拷貝 Session ID")
        default: break
        }
    }

    /// ＋ 新衛星 選單「新任務⋯」
    static func newTask(tell: @escaping @MainActor (String) -> Void) {
        FormPanel.show("新任務") { close in NewTaskSheet(folders: folders(BoardModel.shared.cards), onDone: tell, close: close) }
    }

    /// 新任務可選的資料夾：看板上出現過的專案根目錄
    static func folders(_ cards: [BoardCard]) -> [String] {
        var seen: [String] = []
        for c in cards { if let r = c.cwd.map(gitRoot), r != BoardPaths.home, !seen.contains(r) { seen.append(r) } }
        return seen
    }
    static func gitRoot(_ p: String) -> String {
        var d = p
        while d.count > 1 && d != BoardPaths.home {
            if FileManager.default.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return p
    }
}

/// 選單項目自己帶動作（不用 target／selector）
private final class ActionItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// 表單小面板：同時只開一個；測試模式開在所有螢幕外、不搶焦點
@MainActor
enum FormPanel {
    private(set) static var current: NSPanel?
    static func show<V: View>(_ title: String, _ make: (@escaping () -> Void) -> V) {
        current?.close()
        let p = OffscreenPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = title
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: make { [weak p] in p?.close(); if current === p { current = nil } })
        p.setContentSize(p.contentView?.fittingSize ?? NSSize(width: 480, height: 300))
        current = p
        if AppTest.mode {
            let far = NSScreen.screens.map(\.frame).reduce(NSRect.zero) { $0.union($1) }
            p.setFrameOrigin(NSPoint(x: far.maxX + 4000, y: far.minY))
            p.orderFront(nil)
            return
        }
        p.center()
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }
}

/// 測試用面板：不被系統拉回螢幕範圍內
final class OffscreenPanel: NSPanel {
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { AppTest.mode ? r : super.constrainFrameRect(r, to: screen) }
}

// MARK: - 表單（從 BoardWindow.swift 搬來，行為不變；dismiss 改成 close）

struct SendBackSheet: View {
    let card: BoardCard
    let onDone: @MainActor (String) -> Void
    var close: () -> Void = {}
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("退回「\(card.title)」").font(.headline)
            Text("這句話會打進那個 session 並送出（在 tmux 裡）；不在 tmux 的會拷貝到剪貼簿並跳過去。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            HStack {
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button("送出") {
                    switch BoardActions.sendBack(card, text: text) {
                    case .typed: onDone("已送進「\(card.title)」")
                    case .copied(let m): onDone(m)
                    }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// 看板上直接派工（可設接力：它做完自動交給下一個）
struct DispatchSheet: View {
    let card: BoardCard
    let others: [String]
    let captain: String?
    let onDone: @MainActor (String) -> Void
    var close: () -> Void = {}
    @State private var text = ""
    @State private var relay = false
    @State private var thenTo = ""
    @State private var thenText = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("派工給 \(card.head)").font(.headline)
            Text(card.workTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if !card.sameProject.isEmpty {
                Label("同專案還有 \(card.sameProject.joined(separator: "、"))", systemImage: "exclamationmark.2").font(.callout).foregroundStyle(.orange)
            }
            Text("訊息會排進它的收件匣，下一次它用工具時讀到，不會打進輸入框。" + (captain == nil ? "回報會用系統通知告訴你。" : "回報會傳給秘書。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            Toggle("做完後自動交給下一個（接力）", isOn: $relay).disabled(others.isEmpty)
            if relay {
                Picker("下一棒", selection: $thenTo) {
                    if thenTo.isEmpty { Text("請選擇").tag("") }
                    ForEach(others, id: \.self) { Text($0).tag($0) }
                }
                TextField("下一棒要做什麼（會附上這一棒的回報）", text: $thenText)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button("派出") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (relay && (thenTo.isEmpty || thenText.trimmingCharacters(in: .whitespaces).isEmpty)))
            }
        }
        .padding(20).frame(width: 480)
    }

    private func send() {
        busy = true; error = nil
        let c = card, t = text, nt = relay ? thenTo : nil, nx = relay ? thenText : nil, cap = captain
        DispatchQueue.global().async {
            let r = BoardActions.dispatch(to: c, text: t, thenTo: nt, thenText: nx, captain: cap)
            DispatchQueue.main.async {
                busy = false
                switch r {
                case .success(let id):
                    BoardModel.shared.append(["ev": "dispatch", "id": id, "to": c.sessionId, "text": t])
                    BoardModel.shared.refresh()
                    onDone("已派工 \(id) 給 \(c.display)"); close()
                case .failure(let e): error = "送不出去：\(e.message)"
                }
            }
        }
    }
}

struct ParkSheet: View {
    let card: BoardCard
    var close: () -> Void = {}
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("把「\(card.title)」丟回待辦").font(.headline)
            TextField("備註（選填），例如：下週再看", text: $note)
            Text("這個 session 一有新動靜，就會自動回到它該在的欄。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button("丟回待辦") { BoardActions.park(card, note: note); close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }
}

struct NewTaskSheet: View {
    let folders: [String]
    let onDone: @MainActor (String) -> Void
    var close: () -> Void = {}
    @State private var folder = ""
    @State private var prompt = ""
    @State private var fullAuto = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新任務").font(.headline)
            Text("在選的資料夾開一個 Claude session，由 Orbit42 直接持有：會打開工作視窗，在裡面就能交代事、看過程、回權限。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("資料夾", selection: $folder) {
                    if folder.isEmpty { Text("請選擇").tag("") }
                    ForEach(folders + (folders.contains(folder) || folder.isEmpty ? [] : [folder]), id: \.self) {
                        Text(($0 as NSString).lastPathComponent).tag($0)
                    }
                }
                Button("選擇⋯") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { folder = u.path }
                }
            }
            if !folder.isEmpty { Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Text("要它做什麼").font(.callout)
            TextEditor(text: $prompt).font(.body).frame(minHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            Toggle("全自動（不問權限，等同 bypassPermissions）", isOn: $fullAuto)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { close() }.keyboardShortcut(.cancelAction)
                Button("開始") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520)
    }

    /// 11-08 H3：改成 Orbit42 自己持有的 session（SessionHost，串流模式），開好就打開工作視窗；不再用 claude --bg
    private func start() {
        if AppTest.mode { onDone("測試：不開新任務"); close(); return }
        busy = true; error = nil
        let r = OwnedActions.start(cwd: folder, prompt: prompt, permissionMode: fullAuto ? "bypassPermissions" : nil)
        busy = false
        switch r {
        case .success(let id):
            BoardModel.shared.refresh()
            WorkWindow.show(id, cwd: folder)
            onDone("已開新任務，工作視窗打開了")
            close()
        case .failure(let e):
            error = e.message.contains("not trusted") ? "這個資料夾還沒信任過：先在終端機進去跑一次 claude 並同意。" : e.message
        }
    }
}

