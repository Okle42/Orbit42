import SwiftUI

/// 11-24 Keng「電腦上的所有視窗都可以看可以用，用分頁的方式，但只在手機上」
@MainActor
final class WindowList: ObservableObject {
    let link: MacLink
    @Published var wins: [MacWin] = []
    @Published var msg = ""
    private var poll: Task<Void, Never>?
    init(link: MacLink) { self.link = link }
    func start() {
        guard poll == nil, !link.isDemo else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let r = try? await OrbitAPI(link: self.link).macWindows() {
                    if r.wins != self.wins { self.wins = r.wins }
                    if r.msg != self.msg { self.msg = r.msg }
                }
                try? await Task.sleep(for: .seconds(MacChrome.live ? 5 : 3))
            }
        }
    }
    func stop() { poll?.cancel(); poll = nil }
}

/// 上面那排分頁：終端機、（這顆衛星的 3D／網頁）、Mac 上每個視窗
struct WindowTabs: View {
    @ObservedObject var model: WindowList
    @Binding var tab: String
    let moons: [String]
    var body: some View {
        VStack(spacing: 2) {
            ScrollViewReader { r in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("term", "終端機")
                        if moons.contains("3d") || tab == "3d" { chip("3d", "3D") }
                        if moons.contains("web") || tab == "web" { chip("web", "衛星網頁") }
                        ForEach(model.wins) { w in chip("win\(w.id)", name(w), dim: !w.on) }
                    }.padding(.horizontal, 10)
                }
                .onChange(of: tab) { _, t in withAnimation { r.scrollTo(t, anchor: .center) } }
            }
            if !model.msg.isEmpty { Text(model.msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 10) }
        }.padding(.vertical, 6)
    }
    /// 同一個 App 開好幾個視窗才加標題
    private func name(_ w: MacWin) -> String {
        model.wins.filter { $0.app == w.app }.count > 1 && !w.title.isEmpty ? w.app + "　" + String(w.title.prefix(12)) : w.app
    }
    private func chip(_ id: String, _ t: String, dim: Bool = false) -> some View {
        Button { tab = id } label: {
            Text(t).font(.subheadline.weight(tab == id ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 12).frame(minHeight: 36)
                .background(tab == id ? Color.gray.opacity(0.4) : Color.gray.opacity(0.15), in: Capsule()).opacity(dim ? 0.55 : 1)
        }.buttonStyle(.plain).id(id)
    }
}

struct WindowScreen: View {
    @StateObject private var model: MacChrome
    init(link: MacLink, window: Int) { _model = StateObject(wrappedValue: MacChrome(link: link, window: window)) }
    var body: some View { WebPaneView(model: model) }
}
