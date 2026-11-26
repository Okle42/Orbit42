import XCTest
@testable import Orbit42

/// Orbit42 帳號（Google 登入）：除了「在 Google 頁面上點帳號」那一步，其他全部在這裡跑過（假網路、測試專用鑰匙圈項目）
@MainActor final class OrbitAccountTests: XCTestCase {
    let service = "ai.okle42.orbit42.account.test-\(UUID().uuidString)"
    var config: OrbitAccountConfig { var c = OrbitAccountConfig(apiKey: "test-key", clientID: "123-abc.apps.googleusercontent.com"); c.keychainService = service; return c }
    override func tearDown() { OrbitKeychain.delete(service: service) }

    func testConfigFromEnvAndCallbackScheme() {
        XCTAssertNil(OrbitAccountConfig.load(bundle: Bundle(for: Self.self), env: [:]))
        let c = OrbitAccountConfig.load(bundle: Bundle(for: Self.self), env: ["ORBIT_FIREBASE_API_KEY": "k", "ORBIT_GOOGLE_CLIENT_ID": "123-abc.apps.googleusercontent.com", "ORBIT_ACCOUNT_KEYCHAIN": "svc"])
        XCTAssertEqual(c?.callbackScheme, "com.googleusercontent.apps.123-abc")
        XCTAssertEqual(c?.redirectURI, "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(c?.keychainService, "svc")
    }

    func testPKCEMatchesRFC7636Example() {
        // RFC 7636 附錄 B 的範例
        XCTAssertEqual(OrbitAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = OrbitAuth.random(48)
        XCTAssertGreaterThanOrEqual(v.count, 43); XCTAssertLessThanOrEqual(v.count, 128)
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(v, OrbitAuth.random(48))
    }

    func testAuthorizeURLAsksOnlyForIdentity() throws {
        let u = OrbitAuth.authorizeURL(config, state: "s1", challenge: "ch")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(u.host, "accounts.google.com")
        XCTAssertEqual(q["scope"], "openid email profile")
        XCTAssertEqual(q["code_challenge_method"], "S256"); XCTAssertEqual(q["code_challenge"], "ch")
        XCTAssertEqual(q["state"], "s1"); XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], config.redirectURI)
        XCTAssertNil(q["client_secret"])
    }

    func testCallbackParsing() throws {
        let base = config.redirectURI
        XCTAssertEqual(try OrbitAuth.code(from: URL(string: base + "?code=4/abc&state=s1")!, state: "s1"), "4/abc")
        XCTAssertThrowsError(try OrbitAuth.code(from: URL(string: base + "?code=4/abc&state=other")!, state: "s1")) { XCTAssertEqual($0 as? OrbitAccountError, .stateMismatch) }
        XCTAssertThrowsError(try OrbitAuth.code(from: URL(string: base + "?error=access_denied&state=s1")!, state: "s1")) { XCTAssertEqual($0 as? OrbitAccountError, .cancelled) }
        XCTAssertThrowsError(try OrbitAuth.code(from: URL(string: base + "?state=s1")!, state: "s1"))
    }

    func testFullFlowAfterGoogleWithFakeNetwork() async throws {
        let acct = OrbitAccount(config: config)
        var seen: [URLRequest] = []
        acct.transport = { r in
            seen.append(r)
            switch r.url?.host {
            case "oauth2.googleapis.com": return (Data(#"{"id_token":"g-id","access_token":"g-at"}"#.utf8), 200)
            case "identitytoolkit.googleapis.com":
                return (Data(#"{"localId":"uid1","email":"demo@example.com","displayName":"示範使用者","refreshToken":"rt1","idToken":"fb-id"}"#.utf8), 200)
            case "securetoken.googleapis.com": return (Data(#"{"id_token":"fb-id2","refresh_token":"rt2"}"#.utf8), 200)
            default: return (Data(), 404)
            }
        }
        XCTAssertEqual(acct.stateJSON["signedIn"] as? Bool, false)
        let info = try await acct.finish(code: "4/abc", verifier: "ver")
        XCTAssertEqual(info, OrbitAccountInfo(uid: "uid1", email: "demo@example.com", name: "示範使用者", photo: nil, refreshToken: "rt1"))

        // Google 換憑證：帶 PKCE 驗證碼、沒有用戶端密鑰
        let tokenBody = String(decoding: seen[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(tokenBody.contains("code_verifier=ver")); XCTAssertTrue(tokenBody.contains("grant_type=authorization_code")); XCTAssertFalse(tokenBody.contains("client_secret"))
        // Firebase：把 Google 憑證交過去
        XCTAssertEqual(seen[1].url?.query, "key=test-key")
        XCTAssertEqual(seen[1].value(forHTTPHeaderField: "X-Ios-Bundle-Identifier"), "ai.okle42.orbit42")     // 金鑰限 bundle id
        let fb = try JSONSerialization.jsonObject(with: seen[1].httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(fb?["postBody"] as? String, "id_token=g-id&providerId=google.com")

        // 鑰匙圈記住了；登入畫面拿到的不含憑證
        XCTAssertEqual(acct.current?.uid, "uid1")
        let pub = acct.stateJSON
        XCTAssertEqual(pub["signedIn"] as? Bool, true); XCTAssertEqual(pub["email"] as? String, "demo@example.com")
        XCTAssertFalse(String(describing: pub).contains("rt1"))

        // 續期：換到新的續期憑證就更新鑰匙圈
        let t = try await acct.freshIDToken()
        XCTAssertEqual(t, "fb-id2"); XCTAssertEqual(acct.current?.refreshToken, "rt2")

        acct.signOut()
        XCTAssertNil(acct.current); XCTAssertEqual(acct.stateJSON["signedIn"] as? Bool, false)
    }

    func testServerErrorsSurface() async {
        let acct = OrbitAccount(config: config)
        acct.transport = { _ in (Data(#"{"error":"invalid_grant","error_description":"Bad Request"}"#.utf8), 400) }
        do { _ = try await acct.finish(code: "x", verifier: "y"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? OrbitAccountError, .http(400, "Bad Request")) }
        XCTAssertNil(acct.current)
    }

    func testNotConfiguredHidesBlock() {
        let acct = OrbitAccount(config: nil)
        XCTAssertEqual(acct.stateJSON["configured"] as? Bool, false)
    }
}
