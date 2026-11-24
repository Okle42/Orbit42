import SwiftUI

/// 11-24 Keng：深淺色只有一個來源＝智能體（球體的配色選單）；衛星終端機、清單、鍵盤列全部跟著變，終端機自己不再有切換鈕。
/// 球體每次換配色會送 {action:"theme", mode, name}。mode＝auto ⇒ 不蓋系統外觀（球體和 App 都看 iPhone 的深淺色）；其他照 name。
@MainActor
final class Look: ObservableObject {
    static let shared = Look()
    @Published private(set) var mode = UserDefaults.standard.string(forKey: "orbit.look.mode") ?? "auto"
    @Published private(set) var name = UserDefaults.standard.string(forKey: "orbit.look.name") ?? "dark"
    @Published private(set) var light = UserDefaults.standard.string(forKey: "orbit.look.name") == "light"
    private var system: ColorScheme?

    /// 給最外層 preferredColorScheme：nil＝跟 iPhone 系統
    var scheme: ColorScheme? { mode == "auto" ? nil : name == "light" ? .light : .dark }

    func fromSphere(mode m: String, name n: String) {
        if mode != m { mode = m }
        if name != n { name = n }
        UserDefaults.standard.set(m, forKey: "orbit.look.mode"); UserDefaults.standard.set(n, forKey: "orbit.look.name")
        settle()
    }
    /// 目前畫面實際的深淺（自動模式看這個，球體那頁沒開著也會跟）
    func systemIs(_ s: ColorScheme) { system = s; settle() }
    private func settle() {
        let l = mode == "auto" ? (system.map { $0 == .light } ?? (name == "light")) : name == "light"
        if l != light { light = l }
    }
}

/// 量最外層實際的深淺色
struct LookProbe: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.onAppear { Look.shared.systemIs(scheme) }.onChange(of: scheme) { _, s in Look.shared.systemIs(s) }
    }
}
