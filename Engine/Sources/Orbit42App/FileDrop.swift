import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Orbit42Core

/// 拖檔案進來（10-25）：把路徑接到這個輸入框的字後面（Inbox.withPaths）；拖進來時框框亮起來
struct FileDrop: ViewModifier {
    @Binding var text: String
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).opacity(over ? 1 : 0))
            .dropDestination(for: URL.self) { urls, _ in
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                text = Inbox.withPaths(text, paths)
                return true
            } isTargeted: { over = $0 }
    }
}

extension View {
    /// 檔案拖到這一區：路徑填進 text
    func fileDrop(_ text: Binding<String>) -> some View { modifier(FileDrop(text: text)) }
}

/// 收件匣的大按鈕：自己畫底色（電視上的Orbit42通常不是前景視窗，系統的 prominent 按鈕會變灰）
private func inboxChoice(_ title: String, _ color: Color, strong: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.callout.weight(strong ? .semibold : .regular))
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(color.opacity(strong ? 0.55 : 0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
