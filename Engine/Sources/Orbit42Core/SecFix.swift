import Foundation
import CoreWLAN

// 本機資安體檢的「修正」按鈕（11-28 Keng：紅燈旁要能按下去就修）。
// 規格：修正要 Keng 按同意、改前先備份原值。所以：
//   • 每個修正先給一句「會做什麼」讓視窗問過再做；
//   • 要改系統設定的用 macOS 的管理員密碼視窗（提示寫明是 Orbit42），改前把原值寫進 seccheck/backups/；
//   • 系統不准程式直接改的（FileVault、SIP、系統更新）就打開對的系統設定頁，讓人自己按。
public struct SecFix: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case openSettings(String)              // 打開系統設定某一頁
        case firewallOn
        case gatekeeperOn
        case removeOpenWifi([String])
        case revertNetwork
    }
    public var item: Int
    public var label: String                    // 按鈕上的字
    public var confirm: String                  // 按下去先問的那句話
    public var kind: Kind
    public var needsAdmin: Bool {
        switch kind { case .openSettings: false; default: true }
    }
}

public enum SecFixer {
    static let pane = (
        fileVault: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault",
        security: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        update: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
        wifi: "x-apple.systempreferences:com.apple.wifi-settings-extension",
        firewall: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
        network: "x-apple.systempreferences:com.apple.Network-Settings.extension",
        sharing: "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
    )

    /// 這一項有沒有修正按鈕（綠燈沒有）
    public static func fix(for i: SecItem, report: SecReport? = nil) -> SecFix? {
        guard i.level != .ok, i.level != .pending else { return nil }
        switch i.no {
        case 1: return SecFix(item: 1, label: "打開 FileVault 設定", confirm: "會打開「系統設定 → 隱私權與安全性 → FileVault」，在那裡按「開啟」。開啟時系統會給你一組復原碼，要記下來。", kind: .openSettings(pane.fileVault))
        case 2: return SecFix(item: 2, label: "打開防火牆", confirm: "會把 macOS 防火牆打開（要輸入 Mac 密碼）。原本的狀態先備份，之後想關可以在系統設定 → 網路 → 防火牆關掉。", kind: .firewallOn)
        case 3:
            if i.detail.contains("Gatekeeper 關") {
                return SecFix(item: 3, label: "打開 Gatekeeper", confirm: "會把 Gatekeeper 打開（要輸入 Mac 密碼），來路不明的 App 打開前會被擋下來問你。原本的狀態先備份。", kind: .gatekeeperOn)
            }
            return SecFix(item: 3, label: "看怎麼修", confirm: "SIP 只能在復原模式改：關機 → 長按電源鍵進「選項」→ 工具程式 → 終端機，輸入 csrutil enable 後重開。會先打開「隱私權與安全性」頁。", kind: .openSettings(pane.security))
        case 4: return SecFix(item: 4, label: "打開軟體更新", confirm: "會打開「系統設定 → 一般 → 軟體更新」，在那裡按「立即更新」。macOS 更新要重開機，先存好手上的工作。", kind: .openSettings(pane.update))
        case 5: return SecFix(item: 5, label: "打開 Wi-Fi 設定", confirm: "會打開 Wi-Fi 設定，換到有密碼（WPA2 或 WPA3）的網路，或改連手機熱點。", kind: .openSettings(pane.wifi))
        case 6:
            let names = openSavedWifi()
            guard !names.isEmpty else { return nil }
            return SecFix(item: 6, label: "刪掉這 \(names.count) 個", confirm: "會從「已知網路」刪掉 \(names.count) 個沒加密的 Wi-Fi：\(names.joined(separator: "、"))（要輸入 Mac 密碼）。名單先備份，要加回來可以照備份重新連。", kind: .removeOpenWifi(names))
        case 7:
            guard i.level == .bad else { return nil }        // 黃燈（基準待確認）用「是我設的」，不用修
            return SecFix(item: 7, label: "改回基準值", confirm: "會把 DNS 和代理改回你確認過的基準（要輸入 Mac 密碼）：多出來的代理關掉、手動 DNS 改回基準。現在的值先備份。", kind: .revertNetwork)
        case 8:
            if i.level == .bad { return SecFix(item: 8, label: "打開防火牆", confirm: "會把 macOS 防火牆打開（要輸入 Mac 密碼），沒允許的程式就連不進來。原本的狀態先備份。", kind: .firewallOn) }
            return SecFix(item: 8, label: "打開防火牆選項", confirm: "會打開「系統設定 → 網路 → 防火牆 → 選項」，把用不到的程式設成「阻擋連入連線」。", kind: .openSettings(pane.firewall))
        case 9: return SecFix(item: 9, label: "打開共享設定", confirm: "會打開「系統設定 → 一般 → 共享」，用不到的遠端登入、螢幕共享可以在那裡關掉。", kind: .openSettings(pane.sharing))
        default: return nil
        }
    }

    public struct Outcome: Sendable { public var ok: Bool; public var message: String; public var backup: String? }

    /// 做修正（同步；要管理員權限的會跳 macOS 密碼視窗，請放背景執行緒）
    public static func apply(_ f: SecFix) -> Outcome {
        switch f.kind {
        case .openSettings(let url):
            let r = SecCheck.sh("/usr/bin/open", [url])
            return Outcome(ok: r.status == 0, message: r.status == 0 ? "已打開系統設定" : "打不開系統設定：\(r.out.firstLine)", backup: nil)
        case .firewallOn:
            let fw = "/usr/libexec/ApplicationFirewall/socketfilterfw"
            let b = backup(item: f.item, before: ["firewall": SecCheck.sh(fw, ["--getglobalstate"]).out.firstLine], commands: [fw + " --setglobalstate on"])
            return admin([[fw, "--setglobalstate", "on"]], why: "打開防火牆", backup: b)
        case .gatekeeperOn:
            let b = backup(item: f.item, before: ["gatekeeper": SecCheck.sh("/usr/sbin/spctl", ["--status"]).out.firstLine], commands: ["/usr/sbin/spctl --global-enable"])
            return admin([["/usr/sbin/spctl", "--global-enable"]], why: "打開 Gatekeeper", backup: b)
        case .removeOpenWifi(let names):
            guard let ifname = CWWiFiClient.shared().interface()?.interfaceName else { return Outcome(ok: false, message: "找不到 Wi-Fi 介面", backup: nil) }
            let cmds = names.map { ["/usr/sbin/networksetup", "-removepreferredwirelessnetwork", ifname, $0] }
            let b = backup(item: f.item, before: ["interface": ifname, "removed": names.joined(separator: "\n"),
                                                  "restore": names.map { "networksetup -addpreferredwirelessnetworkatindex \(ifname) '\($0)' 0 OPEN" }.joined(separator: "\n")],
                           commands: cmds.map { $0.joined(separator: " ") })
            return admin(cmds, why: "刪掉 \(names.count) 個沒加密的已知 Wi-Fi", backup: b)
        case .revertNetwork:
            guard let base = try? BoardJSON.decoder.decode(SecCheck.NetBaseline.self, from: Data(contentsOf: SecCheck.baselineFile)) else {
                return Outcome(ok: false, message: "沒有基準值可以改回", backup: nil)
            }
            let now = SecCheck.networkSnapshot()
            let cmds = revertCommands(now: now, base: base.values, services: SecCheck.services())
            guard !cmds.isEmpty else { return Outcome(ok: true, message: "已經跟基準一樣，不用改", backup: nil) }
            let b = backup(item: f.item, before: ["network": now.joined(separator: "\n")], commands: cmds.map { $0.joined(separator: " ") })
            return admin(cmds, why: "把 DNS／代理改回基準", backup: b)
        }
    }

    /// 改回基準的 networksetup 指令：手動 DNS 跟基準不同就設回（基準沒有＝改回自動）；基準沒有的代理關掉
    public static func revertCommands(now: [String], base: [String], services: [String]) -> [[String]] {
        let ns = "/usr/sbin/networksetup"
        var cmds: [[String]] = []
        func dns(_ list: [String], _ s: String) -> String? { list.first { $0.hasPrefix("DNS[\(s)]=") }.map { String($0.dropFirst("DNS[\(s)]=".count)) } }
        for s in services where dns(now, s) != dns(base, s) {
            let servers = dns(base, s).map { $0.split(separator: ",").map(String.init) } ?? ["Empty"]
            cmds.append([ns, "-setdnsservers", s] + servers)
        }
        let flags: [(String, String)] = [("代理[HTTP]", "-setwebproxystate"), ("代理[HTTPS]", "-setsecurewebproxystate"), ("代理[SOCKS]", "-setsocksfirewallproxystate"),
                                         ("代理[FTP]", "-setftpproxystate"), ("代理[RTSP]", "-setstreamingproxystate"), ("代理[Gopher]", "-setgopherproxystate"),
                                         ("代理[自動設定]", "-setautoproxystate"), ("代理[自動探索]", "-setproxyautodiscovery")]
        for (key, flag) in flags {
            let inNow = now.contains { $0.hasPrefix(key + "=") }, inBase = base.contains { $0.hasPrefix(key + "=") }
            if inNow && !inBase { for s in services { cmds.append([ns, flag, s, "off"]) } }
        }
        return cmds
    }

    /// 已知網路裡沒加密／WEP 的名字
    public static func openSavedWifi() -> [String] {
        let ps = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        return ps.filter { [0, 1, 6].contains($0.security.rawValue) }.compactMap(\.ssid)
    }

    // MARK: 管理員權限（macOS 密碼視窗，提示寫明是 Orbit42）
    static func admin(_ cmds: [[String]], why: String, backup: String?) -> Outcome {
        let shell = cmds.map { $0.map(shQuote).joined(separator: " ") }.joined(separator: " && ")
        let script = "do shell script \(asQuote(shell)) with administrator privileges with prompt \(asQuote("Orbit42 本機資安體檢要\(why)，請輸入 Mac 密碼。"))"
        let r = SecCheck.sh("/usr/bin/osascript", ["-e", script], timeout: 300)
        if r.status == 0 { return Outcome(ok: true, message: "已\(why)", backup: backup) }
        if r.out.contains("-128") { return Outcome(ok: false, message: "你取消了，沒有改", backup: backup) }
        return Outcome(ok: false, message: "沒改成功：\(r.out.firstLine)", backup: backup)
    }
    public static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func asQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// 改之前把原值寫進 seccheck/backups/（回傳檔案路徑）
    static func backup(item: Int, before: [String: String], commands: [String]) -> String? {
        let dir = SecCheck.dir.appendingPathComponent("backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = dir.appendingPathComponent("\(f.string(from: Date()))-item\(item).json")
        let o: [String: Any] = ["item": item, "at": ISO8601DateFormatter().string(from: Date()), "before": before, "commands": commands]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]), (try? d.write(to: url)) != nil else { return nil }
        return url.path
    }
}
