import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

// Orbit42 自己的帳號（11-26 Keng：用 Google 登入，之後拿來收費／授權）。
// 流程：系統登入視窗（ASWebAuthenticationSession）開 Google 官方登入頁＋PKCE → 拿到授權碼 → 換 Google 憑證
// → 交給 Firebase（REST，不塞 SDK）換成 Orbit42 帳號 → 只把 Firebase 的續期憑證和名字／Email 存進這台 Mac 的鑰匙圈。
// 密碼只在 Google 的頁面輸入，Orbit42 碰不到；只要 openid／email／profile，不讀信、不碰雲端硬碟。

/// 設定：從 Info.plist 讀（正式 App），沒有就看環境變數（debug／測試）。這兩個值本來就是公開的用戶端識別，不是密鑰。
struct OrbitAccountConfig: Equatable {
    var apiKey: String          // Firebase 的瀏覽器金鑰（設計上會放在用戶端）
    var clientID: String        // Google OAuth「iOS」類型用戶端：沒有密鑰，用自訂網址回傳
    var keychainService = "ai.okle42.orbit42.account"

    /// com.googleusercontent.apps.<編號>：Google 規定 iOS 類型用戶端的回傳網址開頭
    var callbackScheme: String { "com.googleusercontent.apps." + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "") }
    var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    static func load(bundle: Bundle = .main, env: [String: String] = ProcessInfo.processInfo.environment) -> OrbitAccountConfig? {
        func pick(_ plist: String, _ envKey: String) -> String? {
            let v = (env[envKey] ?? bundle.object(forInfoDictionaryKey: plist) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return v?.isEmpty == false ? v : nil
        }
        guard let key = pick("OrbitFirebaseAPIKey", "ORBIT_FIREBASE_API_KEY"),
              let client = pick("OrbitGoogleClientID", "ORBIT_GOOGLE_CLIENT_ID") else { return nil }
        var c = OrbitAccountConfig(apiKey: key, clientID: client)
        if let s = env["ORBIT_ACCOUNT_KEYCHAIN"], !s.isEmpty { c.keychainService = s }      // 測試用另一個鑰匙圈項目，不碰真的
        return c
    }
}

/// 登入後記住的東西（鑰匙圈裡就這一筆）
struct OrbitAccountInfo: Codable, Equatable {
    var uid: String
    var email: String
    var name: String
    var photo: String?
    var refreshToken: String

    /// 給登入畫面看的（不含憑證）
    var publicJSON: [String: Any] {
        var o: [String: Any] = ["signedIn": true, "uid": uid, "email": email, "name": name]
        if let p = photo { o["photo"] = p }
        return o
    }
}

enum OrbitAccountError: LocalizedError, Equatable {
    case notConfigured, cancelled, badCallback(String), stateMismatch, http(Int, String), badResponse(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "這版 Orbit42 還沒設定 Google 登入"
        case .cancelled: return "已取消登入"
        case .badCallback(let s): return "Google 回傳的網址看不懂：\(s)"
        case .stateMismatch: return "登入回應對不上這次的請求，已拒絕"
        case .http(let c, let m): return "伺服器回應 \(c)：\(m)"
        case .badResponse(let s): return "伺服器回應看不懂：\(s)"
        }
    }
}

/// 不碰網路、不碰畫面的部分（全部可以單元測試）
enum OrbitAuth {
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random(_ n: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return base64url(Data(b))
    }
    /// PKCE（RFC 7636，S256）
    static func challenge(for verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func authorizeURL(_ c: OrbitAccountConfig, state: String, challenge: String) -> URL {
        var u = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        u.queryItems = [
            .init(name: "client_id", value: c.clientID),
            .init(name: "redirect_uri", value: c.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        return u.url!
    }

    /// Google 回傳：<scheme>:/oauth2redirect?code=…&state=…（或 error=…）
    static func code(from callback: URL, state: String) throws -> String {
        let q = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ k: String) -> String? { q.first { $0.name == k }?.value }
        if let e = v("error") { throw e == "access_denied" ? OrbitAccountError.cancelled : OrbitAccountError.badCallback(e) }
        guard v("state") == state else { throw OrbitAccountError.stateMismatch }
        guard let code = v("code"), !code.isEmpty else { throw OrbitAccountError.badCallback(callback.absoluteString) }
        return code
    }

    static func form(_ items: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(items.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }

    static func tokenRequest(_ c: OrbitAccountConfig, code: String, verifier: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = form(["code": code, "client_id": c.clientID, "code_verifier": verifier, "redirect_uri": c.redirectURI, "grant_type": "authorization_code"])
        return r
    }

    /// 金鑰在 Google Cloud 限定只給 ai.okle42.orbit42 用（iOS 類型限制）：請求要帶這個標頭，不然會被擋
    static let bundleHeader = "X-Ios-Bundle-Identifier", bundleID = "ai.okle42.orbit42"

    static func firebaseRequest(_ c: OrbitAccountConfig, googleIDToken: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(c.apiKey)")!)
        r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.setValue(bundleID, forHTTPHeaderField: bundleHeader)
        let post = String(decoding: form(["id_token": googleIDToken, "providerId": "google.com"]), as: UTF8.self)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["postBody": post, "requestUri": "http://localhost", "returnSecureToken": true, "returnIdpCredential": false])
        return r
    }

    static func refreshRequest(_ c: OrbitAccountConfig, refreshToken: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(c.apiKey)")!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); r.setValue(bundleID, forHTTPHeaderField: bundleHeader)
        r.httpBody = form(["grant_type": "refresh_token", "refresh_token": refreshToken])
        return r
    }

    static func json(_ data: Data, status: Int) throws -> [String: Any] {
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let msg = ((j?["error"] as? [String: Any])?["message"] as? String) ?? (j?["error_description"] as? String) ?? (j?["error"] as? String) ?? "\(data.count) bytes"
            throw OrbitAccountError.http(status, msg)
        }
        guard let j else { throw OrbitAccountError.badResponse(String(decoding: data.prefix(200), as: UTF8.self)) }
        return j
    }

    static func info(fromFirebase j: [String: Any]) throws -> OrbitAccountInfo {
        guard let uid = j["localId"] as? String, let rt = j["refreshToken"] as? String else { throw OrbitAccountError.badResponse("少了 localId／refreshToken") }
        let email = j["email"] as? String ?? ""
        return OrbitAccountInfo(uid: uid, email: email, name: (j["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? email,
                                photo: j["photoUrl"] as? String, refreshToken: rt)
    }
}

/// 鑰匙圈：一個 service 一筆
enum OrbitKeychain {
    private static func base(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "firebase"]
    }
    static func save(_ info: OrbitAccountInfo, service: String) -> Bool {
        guard let d = try? JSONEncoder().encode(info) else { return false }
        SecItemDelete(base(service) as CFDictionary)
        var q = base(service); q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly     // 不跟 iCloud 鑰匙圈同步、不帶去別台
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func load(service: String) -> OrbitAccountInfo? {
        var q = base(service); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(OrbitAccountInfo.self, from: d)
    }
    @discardableResult static func delete(service: String) -> Bool {
        let s = SecItemDelete(base(service) as CFDictionary); return s == errSecSuccess || s == errSecItemNotFound
    }
}

/// 帳號本體：登入、登出、目前是誰
@MainActor
final class OrbitAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias Transport = (URLRequest) async throws -> (Data, Int)
    static let shared = OrbitAccount()

    let config: OrbitAccountConfig?
    var transport: Transport = { r in let (d, resp) = try await URLSession.shared.data(for: r); return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0) }
    weak var anchor: NSWindow?
    private var session: ASWebAuthenticationSession?

    init(config: OrbitAccountConfig? = OrbitAccountConfig.load()) { self.config = config }

    var current: OrbitAccountInfo? { config.flatMap { OrbitKeychain.load(service: $0.keychainService) } }

    /// 給登入畫面：{configured, signedIn, name, email}
    var stateJSON: [String: Any] {
        guard config != nil else { return ["configured": false, "signedIn": false] }
        var o = current?.publicJSON ?? ["signedIn": false]; o["configured"] = true; return o
    }

    /// 授權碼之後的步驟（測試直接打這裡，換掉 transport）
    func finish(code: String, verifier: String) async throws -> OrbitAccountInfo {
        guard let c = config else { throw OrbitAccountError.notConfigured }
        let (d1, s1) = try await transport(OrbitAuth.tokenRequest(c, code: code, verifier: verifier))
        guard let idToken = try OrbitAuth.json(d1, status: s1)["id_token"] as? String else { throw OrbitAccountError.badResponse("Google 沒給 id_token") }
        let (d2, s2) = try await transport(OrbitAuth.firebaseRequest(c, googleIDToken: idToken))
        let info = try OrbitAuth.info(fromFirebase: OrbitAuth.json(d2, status: s2))
        guard OrbitKeychain.save(info, service: c.keychainService) else { throw OrbitAccountError.badResponse("存不進鑰匙圈") }
        return info
    }

    /// 打開系統登入視窗（Google 官方頁）→ 完成後回傳帳號
    func signIn() async throws -> OrbitAccountInfo {
        guard let c = config else { throw OrbitAccountError.notConfigured }
        let verifier = OrbitAuth.random(48), state = OrbitAuth.random(16)
        let url = OrbitAuth.authorizeURL(c, state: state, challenge: OrbitAuth.challenge(for: verifier))
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: c.callbackScheme) { u, e in
                if let u { cont.resume(returning: u) }
                else if let e = e as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: OrbitAccountError.cancelled) }
                else { cont.resume(throwing: e ?? OrbitAccountError.cancelled) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false     // 瀏覽器已登入的 Google 帳號可以直接選
            session = s
            if !s.start() { cont.resume(throwing: OrbitAccountError.badCallback("系統登入視窗開不起來")) }
        }
        session = nil
        return try await finish(code: OrbitAuth.code(from: callback, state: state), verifier: verifier)
    }

    /// 之後要呼叫自己的伺服器（授權、收費）時用：拿一張新鮮的 Firebase 憑證
    func freshIDToken() async throws -> String {
        guard let c = config, var info = current else { throw OrbitAccountError.notConfigured }
        let (d, s) = try await transport(OrbitAuth.refreshRequest(c, refreshToken: info.refreshToken))
        let j = try OrbitAuth.json(d, status: s)
        guard let t = j["id_token"] as? String else { throw OrbitAccountError.badResponse("沒給 id_token") }
        if let rt = j["refresh_token"] as? String, rt != info.refreshToken { info.refreshToken = rt; _ = OrbitKeychain.save(info, service: c.keychainService) }
        return t
    }

    func signOut() { if let c = config { OrbitKeychain.delete(service: c.keychainService) } }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
    }
}
