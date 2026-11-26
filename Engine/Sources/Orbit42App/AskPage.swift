import CryptoKit
import Foundation
import MachO
import Security
import WebKit

// 11-25 答案卡網頁免重開（T1125194238）：整包換新後，只有「同一個簽章身分、簽章驗過、執行檔程式碼相同」的新包才拿它的 ask.html。
// 有一項不符就等重開。讀進記憶體的那一份就是驗過的那一份，載入時不再讀磁碟。

/// 只回一頁：記憶體裡那一份 ask.html，別的網址一律 404
final class AskPageHandler: NSObject, WKURLSchemeHandler {
    let data: Data
    init(_ d: Data) { data = d }
    func webView(_ w: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let ok = url.absoluteString == "\(WebSchemeHandler.scheme)://web/ask.html", body = ok ? data : Data("not found".utf8)
        task.didReceive(HTTPURLResponse(url: url, statusCode: ok ? 200 : 404, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": ok ? "text/html; charset=utf-8" : "text/plain", "Content-Length": "\(body.count)", "Cache-Control": "no-store"])!)
        task.didReceive(body); task.didFinish()
    }
    func webView(_ w: WKWebView, stop task: any WKURLSchemeTask) {}
}

enum AskPage {
    enum Fail: Error, Equatable { case read, signature(OSStatus), binary }
    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    /// 整份讀進記憶體；只收一般檔案（不跟著捷徑走）
    static func read(_ u: URL) -> Data? {
        var st = stat()
        guard lstat(u.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size < 2_000_000, let d = try? Data(contentsOf: u), d.count == Int(st.st_size) else { return nil }
        return d
    }
    /// Mach-O 的 LC_UUID（同一份程式碼才相同；重簽不會變）
    static func uuid(_ p: UnsafeRawBufferPointer) -> UUID? {
        guard p.count >= 32, p.loadUnaligned(as: UInt32.self) == MH_MAGIC_64 else { return nil }
        var at = 32
        for _ in 0..<min(p.loadUnaligned(fromByteOffset: 16, as: UInt32.self), 4096) {
            guard at + 8 <= p.count else { return nil }
            let size = Int(p.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            if p.loadUnaligned(fromByteOffset: at, as: UInt32.self) == LC_UUID { return at + 24 <= p.count ? UUID(uuid: p.loadUnaligned(fromByteOffset: at + 8, as: uuid_t.self)) : nil }
            guard size >= 8 else { return nil }
            at += size
        }
        return nil
    }
    static func uuid(file: URL) -> UUID? { (try? Data(contentsOf: file, options: .alwaysMapped)).flatMap { $0.withUnsafeBytes { uuid($0) } } }
    static var runningUUID: UUID? {
        guard let h = _dyld_get_image_header(0) else { return nil }
        return uuid(UnsafeRawBufferPointer(start: h, count: 32 + Int(h.pointee.sizeofcmds)))
    }
    /// 自己的簽章身分（識別碼＋憑證）。沒憑證的簽章是 cdhash，新包一定對不上 ⇒ 不會熱換
    static var ownRequirement: SecRequirement? {
        var c: SecCode?, s: SecStaticCode?, r: SecRequirement?
        guard SecCodeCopySelf([], &c) == errSecSuccess, let c, SecCodeCopyStaticCode(c, [], &s) == errSecSuccess, let s, SecCodeCopyDesignatedRequirement(s, [], &r) == errSecSuccess else { return nil }
        return r
    }
    /// 讀進記憶體 → 驗整包簽章與身分 → 拿記憶體那一份去對簽章裡封的雜湊 → 比執行檔。
    /// 不可以靠「前後讀兩次一樣」：驗的那一瞬間可以換成好的、驗完再換回來（Dora 11-25 實測收得進沒簽的頁）
    static func fetch(bundle: URL, executable: String, requirement: SecRequirement, uuid want: UUID) -> Result<Data, Fail> {
        let page = bundle.appendingPathComponent("Contents/Resources/Web/ask.html")
        guard let d = read(page) else { return .failure(.read) }
        var s: SecStaticCode?
        var e = SecStaticCodeCreateWithPath(bundle as CFURL, [], &s)
        if e == errSecSuccess, let s { e = SecStaticCodeCheckValidity(s, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) }
        guard e == errSecSuccess, let s else { return .failure(.signature(e)) }
        let r = SecCodeValidateFileResource(s, "Resources/Web/ask.html" as CFString, d as CFData, [])
        guard r == errSecSuccess else { return .failure(.signature(r)) }
        guard uuid(file: bundle.appendingPathComponent("Contents/MacOS/\(executable)")) == want else { return .failure(.binary) }
        return .success(d)
    }
}

/// 看 App 那個資料夾有沒有被換（系統通知，不輪詢）：安靜 1 秒後在背景驗新包，驗過才交出網頁
@MainActor
final class AskPageWatch {
    private let bundle: URL, executable: String, requirement: SecRequirement, uuid: UUID
    private var source: (any DispatchSourceFileSystemObject)?, turn = 0
    private let found: (Result<Data, AskPage.Fail>) -> Void
    init?(bundle: URL, executable: String, requirement: SecRequirement?, uuid: UUID?, found: @escaping (Result<Data, AskPage.Fail>) -> Void) {
        guard bundle.pathExtension == "app", let requirement, let uuid else { return nil }
        self.bundle = bundle; self.executable = executable; self.requirement = requirement; self.uuid = uuid; self.found = found
        let fd = open(bundle.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume(); source = s
    }
    func stop() { source?.cancel(); source = nil; turn += 1 }
    private func changed() {
        turn += 1; let mine = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in MainActor.assumeIsolated { if let self, self.turn == mine { self.check(mine) } } }
    }
    private func check(_ mine: Int) {
        let (b, x, u) = (bundle, executable, uuid)
        nonisolated(unsafe) let r = requirement
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let got = AskPage.fetch(bundle: b, executable: x, requirement: r, uuid: u)
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self, self.turn == mine { self.found(got) } } }
        }
    }
}
