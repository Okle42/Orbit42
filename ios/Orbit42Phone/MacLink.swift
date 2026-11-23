import Foundation
import Security

/// 連到哪一台 Mac：ShoWork 網頁戰情中心的網址（`showork web enable` 印出來的那行，`http://100.x.y.z:埠/?t=token`）。
/// token 就是密碼 ⇒ 存鑰匙圈，不存 UserDefaults。示範模式不連線，用球體網頁內建的假資料。
struct MacLink: Equatable, Sendable {
    var host: String
    var port: Int
    var token: String

    static let demo = MacLink(host: "demo", port: 0, token: "")
    var isDemo: Bool { host == "demo" }
    var base: URL { URL(string: "http://\(host):\(port)")! }

    /// 貼上的網址（或 QR code 內容）→ MacLink。只收 Tailscale 位址（100.64.0.0/10），跟 Mac 那端的規則一樣
    static func parse(_ s: String) -> MacLink? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "http",
              let h = c.host, isTailscale(h), let p = c.port,
              let t = c.queryItems?.first(where: { $0.name == "t" })?.value, t.count >= 32 else { return nil }
        return MacLink(host: h, port: p, token: t)
    }

    static func isTailscale(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { UInt8($0) }
        return o.count == 4 && o[0] == 100 && (o[1] & 0xC0) == 64
    }

    // MARK: 鑰匙圈

    private static let service = "ai.okle42.orbit42.phone.link"

    static func load() -> MacLink? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s == "demo" ? .demo : parse(s)
    }

    func save() {
        MacLink.forget()
        let s = isDemo ? "demo" : "http://\(host):\(port)/?t=\(token)"
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: MacLink.service,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecValueData as String: Data(s.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func forget() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// 連線統計（衛星分頁顯示；紅條只在連續失敗時才出現）
@MainActor final class NetStats: ObservableObject {
    static let shared = NetStats()
    @Published private(set) var ok = 0
    @Published private(set) var fail = 0
    @Published private(set) var streak = 0
    @Published private(set) var lastError = ""
    func success() { ok += 1; streak = 0 }
    func failure(_ e: String) { fail += 1; streak += 1; lastError = e }
    /// 連續失敗 3 次（約 6 秒都沒成功）才算真的斷線；偶爾一次失敗就安靜重試
    var down: Bool { streak >= 3 }
}

/// 一次只送一個請求（11-23：球體、衛星清單、衛星畫面三條同時擠進內建 Tailscale 的轉接通道，常有一條失敗）
actor RequestGate {
    static let shared = RequestGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

/// Mac 上 Orbit42 的 API（讀畫面＋回答答案卡＋11-24 起衛星終端機輸入）。全部帶 X-ShoWork-Token 標頭
struct OrbitAPI: Sendable {
    let link: MacLink

    enum Failure: Error, LocalizedError {
        case status(Int, String), offline(String)
        var errorDescription: String? {
            switch self {
            case .status(let c, let m): return c == 403 ? "連不上：\(m)（網址或密碼可能換過了）" : "\(m)（\(c)）"
            case .offline(let m): return "連不到 Mac：\(m)（Mac 開著嗎？上面的 Tailscale 有顯示已連上嗎？）"
            }
        }
    }

    private func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        var c = URLComponents(url: link.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 8)
        r.setValue(link.token, forHTTPHeaderField: "X-ShoWork-Token")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        await RequestGate.shared.enter()
        defer { Task { await RequestGate.shared.leave() } }
        let (d, resp): (Data, URLResponse)
        // App 內建 Tailscale 上線了就走它（不用開 Tailscale App）；還沒上線才用系統網路（手機有開 Tailscale App 時也通）。
        // 11-23：通道可能被 iOS 收回（背景、切 App）⇒ 連不上就重開通道再試一次
        do { (d, resp) = try await Tailnet.sessionForRequest(retry: false).data(for: r) }
        catch {
            do { (d, resp) = try await Tailnet.sessionForRequest(retry: true).data(for: r) }
            catch {
                await NetStats.shared.failure(error.localizedDescription)
                // 通道重開了還是連不上、連續 3 次 ⇒ 節點本身卡住（常見：出門換行動網路、背景太久）⇒ 整個重開
                if await NetStats.shared.down { await Tailnet.shared.heal(reason: "連續連不上 Mac") }
                throw Failure.offline(error.localizedDescription)
            }
        }
        await NetStats.shared.success()
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String ?? "出錯了"
            throw Failure.status(code, msg)
        }
        return d
    }

    /// 球體資料（跟 Mac 球體 karaUpdate 同一份）
    func sphere() async throws -> Data { try await request("api/sphere") }
    /// 衛星清單（JSON 陣列：id、name、brain、brainLabel、state…）
    func sats() async throws -> Data { try await request("api/sats") }
    /// 某顆衛星從第 from 個位元組起的終端機輸出 → (總長, 這段從哪開始, 內容)
    func screen(_ id: String, from: Int) async throws -> Screen {
        let d = try await request("api/sat", query: [URLQueryItem(name: "id", value: id), URLQueryItem(name: "from", value: String(from))])
        let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
        let size = (o["cols"] as? Int).flatMap { c in (o["rows"] as? Int).map { (cols: c, rows: $0) } }
        return Screen(total: o["total"] as? Int ?? 0, from: o["from"] as? Int ?? 0,
                      data: Data(base64Encoded: o["data"] as? String ?? "") ?? Data(), size: size)
    }
    struct Screen: Sendable { let total: Int, from: Int, data: Data; let size: (cols: Int, rows: Int)? }
    /// 11-24 衛星終端機輸入（鍵盤、滑鼠點擊／滾輪的跳脫序列）→ Mac 寫進那顆衛星的終端機
    func input(_ id: String, _ data: Data) async throws {
        _ = try await request("api/input", body: ["id": id, "data": data.base64EncodedString()])
    }
    /// 回答答案卡（走 Mac 跟收件匣按鈕同一條路；Mac 那端會記稽核）
    func answer(session: String, text: String) async throws -> String {
        let d = try await request("api/answer", body: ["id": session, "text": text])
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["message"] as? String ?? "已送出"
    }
}

/// 一顆衛星（Mac Satellites.swift 的 json）
struct Sat: Identifiable, Hashable, Sendable {
    let id: String, name: String, brain: String, brainLabel: String, state: String
    var sessionId: String? = nil
    var json: [String: Any] { ["id": id, "name": name, "brain": brain, "brainLabel": brainLabel, "state": state] }

    static func list(_ d: Data) -> [Sat] {
        ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] ?? []).compactMap { o in
            guard let id = o["id"] as? String else { return nil }
            return Sat(id: id, name: o["name"] as? String ?? id, brain: o["brain"] as? String ?? "claude",
                       brainLabel: o["brainLabel"] as? String ?? "Claude", state: o["state"] as? String ?? "open",
                       sessionId: o["sessionId"] as? String)
        }
    }
    static let demo = [Sat(id: "demo1", name: "Claude 1", brain: "claude", brainLabel: "Claude", state: "busy"),
                       Sat(id: "demo2", name: "Claude 2", brain: "claude", brainLabel: "Claude", state: "open")]
}
