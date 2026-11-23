import Foundation
import Network
import TailscaleKit

/// App 內建 Tailscale（11-23 Keng：「以後不用開 Tailscale App」；做法來自 Ruby4 的 TS實測驗證）：
/// TailscaleKit（libtailscale 的 userspace 節點）讓 App 自己加入 okle42.ai 的 tailnet，不用 VPN／Network Extension 權限。
/// 連 Mac 的請求一律走這個節點開的本機 SOCKS5（URLSessionConfiguration.tailscaleSession）。
/// 第一次要登入（打開 Tailscale 給的網址、用 okle42.ai 帳號），登入狀態存在 App 自己的資料夾，之後打開就自動上線。
@MainActor
final class Tailnet: ObservableObject {
    static let shared = Tailnet()

    enum State: Equatable { case off, starting, needsLogin(URL), running(String), failed(String) }
    @Published private(set) var state: State = .off

    /// 連 Mac 用的 URLSession（節點上線後才有；OrbitAPI 用它）
    nonisolated(unsafe) static var session: URLSession?

    private var node: TailscaleNode?
    private var poller: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { return true }; return false }

    func start() {
        guard node == nil else { return }
        state = .starting
        Task {
            do {
                let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tailscale")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // 不是 ephemeral：登入一次就記住（App 移除才會忘）；Mac 的 tailscale status 會看到 orbit42-phone
                let cfg = Configuration(hostName: "orbit42-phone", path: dir.path, authKey: nil, controlURL: kDefaultControlURL, ephemeral: false)
                let n = try TailscaleNode(config: cfg, logger: TSLog())
                node = n
                // up() 會一直等到登入完成 ⇒ 另開 task；登入網址與狀態用 statusJSON 每 2 秒讀（TS實測：IPN bus 的訊息解碼常失敗，這個穩）
                Task.detached { try? await n.up() }
                poll(n)
            } catch { state = .failed("Tailscale 啟動失敗：\(error.localizedDescription)") }
        }
    }

    /// 連線方式（畫面上顯示，方便看是不是真的走內建 Tailscale）
    @Published private(set) var route = "還沒建立"

    /// 從背景回來：iOS 可能收回本機的 SOCKS5 listener（Ruby4 提醒）⇒ 重新拿一次連線設定
    func refresh() { Task { _ = await makeSession() } }

    // MARK: 出門不斷線（11-24 Keng：「出門手機上的 Orbit42 不會斷線嗎？把這個問題先修好」）
    // ① 網路換了（Wi-Fi ⇄ 行動網路、換 Wi-Fi）：節點的 UDP 還綁在舊網路上 ⇒ 重開節點（登入狀態在磁碟上，幾秒就回來）
    // ② 連續失敗（通道重開也沒用、節點卡死）：一樣重開節點；最快 20 秒一次，不會一直重開
    private let pathMonitor = NWPathMonitor()
    private var lastPathKey = ""
    private var lastHeal = Date.distantPast
    @Published private(set) var heals = 0

    func watchNetwork() {
        pathMonitor.pathUpdateHandler = { path in
            let key = path.status == .satisfied
                ? path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map(\.name).joined(separator: ",") : "none"
            Task { @MainActor in Tailnet.shared.pathChanged(key) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "orbit42.path"))
    }

    private func pathChanged(_ key: String) {
        defer { lastPathKey = key }
        guard !lastPathKey.isEmpty, key != lastPathKey, key != "none" else { return }   // 第一次回報、斷網那一下不算
        heal(reason: "網路換了（\(lastPathKey) → \(key)）")
    }

    /// 把內建 Tailscale 整個關掉重開（不是只重開通道）
    func heal(reason: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastHeal) > 20 else { return }
        lastHeal = Date(); heals += 1
        route = "重新連線中：\(reason)"
        let old = node
        node = nil; poller?.cancel(); Tailnet.session = nil; state = .off
        Task {
            try? await old?.close()
            start()
        }
    }

    /// 開（或重開）走內建 Tailscale 的連線；失敗就留著錯誤原因，不偷偷改走一般網路
    @discardableResult
    func makeSession() async -> URLSession? {
        guard let n = node, isRunning else { return nil }
        do {
            let (c, _) = try await URLSessionConfiguration.tailscaleSession(n)
            c.timeoutIntervalForRequest = 10
            c.timeoutIntervalForResource = 20
            let s = URLSession(configuration: c)
            Tailnet.session = s
            route = "內建 Tailscale"
            return s
        } catch {
            Tailnet.session = nil
            route = "內建 Tailscale 通道開不起來：\(error)"
            return nil
        }
    }

    /// OrbitAPI 用：內建 Tailscale 上線了就一定要拿到它的連線（沒有就現開）；還沒上線才用一般網路
    nonisolated static func sessionForRequest(retry: Bool) async -> URLSession {
        if !retry, let s = session { return s }
        if let s = await Tailnet.shared.makeSession() { return s }
        return .shared
    }

    private func poll(_ n: TailscaleNode) {
        poller?.cancel()
        poller = Task {
            while !Task.isCancelled {
                if let d = try? await n.statusJSON(), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let st = j["BackendState"] as? String ?? ""
                    if st == "Running" {
                        if !isRunning {
                            let ip = (try? await n.addrs())?.ip4 ?? ""
                            state = .running(ip)
                            await makeSession()
                        }
                    } else if let u = j["AuthURL"] as? String, !u.isEmpty, let url = URL(string: u) {
                        if state != .needsLogin(url) { state = .needsLogin(url) }
                    } else if !isRunning, state != .starting { state = .starting }
                }
                try? await Task.sleep(for: .seconds(isRunning ? 10 : 2))
            }
        }
    }
}

struct TSLog: TailscaleKit.LogSink {
    var logFileHandle: Int32? = nil
    func log(_ message: String) {
        #if DEBUG
        print("ts: \(message)")
        #endif
    }
}
