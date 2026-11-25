import Foundation
import WebKit

/// showork://web/<路徑> ⇒ Web 資料夾裡的檔案（ES module 要正確的 MIME；不准跳出資料夾）
final class WebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "showork"
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    static let mime: [String: String] = [
        "html": "text/html", "htm": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
        "json": "application/json", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "glb": "model/gltf-binary", "gltf": "model/gltf+json",
        "bin": "application/octet-stream", "wasm": "application/wasm", "woff": "font/woff", "woff2": "font/woff2",
        "ttf": "font/ttf", "otf": "font/otf", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "txt": "text/plain",
        "ktx2": "image/ktx2", "hdr": "application/octet-stream",
    ]

    /// 路徑 → 檔案（nil＝不准或不存在）
    func file(for url: URL) -> URL? {
        let rel = url.path.removingPercentEncoding ?? url.path
        guard !rel.split(separator: "/").contains("..") else { return nil }
        let f = root.appendingPathComponent(String(rel.drop { $0 == "/" })).standardizedFileURL
        guard f.path.hasPrefix(root.path + "/") else { return nil }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: f.path, isDirectory: &dir), !dir.boolValue else { return nil }
        return f
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        guard let f = file(for: url), let data = try? Data(contentsOf: f) else {
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            task.didReceive(r); task.didReceive(Data("not found".utf8)); task.didFinish()
            return
        }
        var type = Self.mime[f.pathExtension.lowercased()] ?? "application/octet-stream"
        if type.hasPrefix("text/") || type.hasSuffix("json") || type.hasSuffix("javascript") { type += "; charset=utf-8" }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Cache-Control": "no-cache"])!
        task.didReceive(r)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// WKUserContentController 會強引用 handler：中間隔一層 weak，宿主才放得掉
public final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    public init(_ t: any WKScriptMessageHandler) { target = t }
    public func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
}
