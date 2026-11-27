import Foundation
import Testing
@testable import Orbit42Core

// 11-28 本機資安體檢：判燈規則（輸出片段照這台 Mac 11-28 實跑的格式）
@Suite("SecCheck")
struct SecCheckTests {
    @Test("Wi-Fi：沒加密、WEP 紅；舊 WPA 黃；WPA2／WPA3 綠；沒連線只列出")
    func wifi() {
        #expect(SecCheck.wifiItem(rawSecurity: 0).level == .bad)        // 連沒加密熱點要亮紅燈（規格驗收）
        #expect(SecCheck.wifiItem(rawSecurity: 1).level == .bad)
        #expect(SecCheck.wifiItem(rawSecurity: 6).level == .bad)
        #expect(SecCheck.wifiItem(rawSecurity: 2).level == .warn)
        #expect(SecCheck.wifiItem(rawSecurity: 4).level == .ok)
        #expect(SecCheck.wifiItem(rawSecurity: 11).level == .ok)
        #expect(SecCheck.wifiItem(rawSecurity: Int.max).level == .info)
        #expect(SecCheck.wifiItem(rawSecurity: 0).why?.contains("修") == true)
    }

    @Test("存過的 Wi-Fi：有沒加密的就紅，列出名字")
    func saved() {
        #expect(SecCheck.savedWifiItem([("家", 4), ("店", 13)]).level == .ok)
        let r = SecCheck.savedWifiItem([("家", 4), ("咖啡廳", 0)])
        #expect(r.level == .bad && r.detail.contains("咖啡廳"))
    }

    @Test("FileVault／防火牆／SIP")
    func system() {
        #expect(SecCheck.fileVaultItem("FileVault is On.\n").level == .ok)
        #expect(SecCheck.fileVaultItem("FileVault is Off.\n").level == .bad)
        #expect(SecCheck.firewallItem(global: "Firewall is enabled. (State = 1)", stealth: "Firewall stealth mode is off").level == .ok)
        #expect(SecCheck.firewallItem(global: "Firewall is disabled. (State = 0)", stealth: "").level == .bad)
        #expect(SecCheck.integrityItem(sip: "System Integrity Protection status: enabled.", gk: "assessments enabled").level == .ok)
        #expect(SecCheck.integrityItem(sip: "System Integrity Protection status: disabled.", gk: "assessments enabled").level == .bad)
        #expect(SecCheck.integrityItem(sip: "System Integrity Protection status: enabled.", gk: "assessments disabled").level == .bad)
    }

    @Test("待裝更新")
    func updates() {
        #expect(SecCheck.updatesItem("Software Update Tool\n\nFinding available software\nNo new software available.\n").level == .ok)
        let out = "Software Update found the following new or updated software:\n* Label: macOS Tahoe 26.2-25C56\n\tTitle: macOS Tahoe 26.2, Version: 26.2, Size: 7G, Recommended: YES, Action: restart,\n"
        let r = SecCheck.updatesItem(out)
        #expect(r.level == .bad && r.detail.contains("macOS Tahoe 26.2"))
        #expect(SecCheck.updatesItem("Can't connect\n").level == .warn)
    }

    @Test("DNS／代理：第一次黃、確認後同值綠、被改紅")
    func network() {
        let now = ["DNS[Wi-Fi]=1.1.1.1"]
        #expect(SecCheck.networkItem(now: now, base: nil).level == .warn)
        #expect(SecCheck.networkItem(now: now, base: .init(values: now, accepted: false, at: Date())).level == .warn)
        #expect(SecCheck.networkItem(now: now, base: .init(values: now, accepted: true, at: Date())).level == .ok)
        let r = SecCheck.networkItem(now: now + ["代理[HTTP]=evil:8080"], base: .init(values: now, accepted: true, at: Date()))
        #expect(r.level == .bad && r.detail.contains("evil"))
        let p = SecCheck.proxyValues("<dictionary> {\n  HTTPEnable : 1\n  HTTPProxy : 10.0.0.9\n  HTTPPort : 3128\n  FTPPassive : 1\n}")
        #expect(p == ["代理[HTTP]=10.0.0.9:3128"])
    }

    let netstat = """
    tcp4       0      0  127.0.0.1.8761         *.*                    LISTEN                 0            0  131072  131072           Python:89087  00000 00000006 000000000022b5bc 00000000 00000800      1      0 000000
    tcp4       0      0  100.64.0.5.8743     *.*                    LISTEN                 0            0  131072  131072          Orbit42:90949  00100 00000006 000000000013e7b5 00000000 00080800      1      0 000000
    tcp4       0      0  127.0.0.1.6463         *.*                    LISTEN                 0            0  131072  131072 Discord Helper (:2230   00100 00000106 000000000000417d 00000001 00000800      1      0 000000
    tcp4       0      0  *.59869                *.*                    LISTEN                 0            0  131072  131072 logioptionsplus_:1194   00100 00000002 00000000000034eb 00000000 00000800      1      0 000000
    tcp4       0      0  *.5000                 *.*                    LISTEN                 0            0  131072  131072    ControlCenter:794    00100 00000006 000000000000182f 00000001 00000800      1      0 000000
    tcp4       0      0  *.5900                 *.*                    LISTEN                 0            0  131072  131072          launchd:1      00180 00000006 0000000000000bd4 00000000 00000800      1      0 000000
    tcp4       0      0  10.0.0.5.443           1.2.3.4.5555           ESTABLISHED            0            0  131072  131072          Safari:1      00180 00000006 0000000000000bd4 00000000 00000800      1      0 000000
    """

    @Test("連接埠：本機、Tailscale 不算對外；第三方對外黃；防火牆關紅")
    func ports() {
        let ls = SecCheck.Listeners.parse(netstat)
        #expect(ls.count == 6)
        #expect(ls.contains(.init(proc: "Discord Helper (", addr: "127.0.0.1", port: 6463)))
        #expect(ls.filter(SecCheck.Listeners.external).map(\.port) == [59869, 5000, 5900])
        let w = SecCheck.portsItem(ls, firewallOff: false)
        #expect(w.level == .warn && w.detail.contains("logioptionsplus_（59869）"))
        #expect(SecCheck.portsItem(ls, firewallOff: true).level == .bad)
        #expect(SecCheck.portsItem(ls.filter { $0.proc != "logioptionsplus_" }, firewallOff: false).level == .ok)
    }

    @Test("lsof 備援：解析位址、連接埠、名字裡的空白")
    func lsof() {
        let out = """
        COMMAND     PID         USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    729 demo    6u  IPv4 0xae3449fbcbc94e4f      0t0  TCP *:49182 (LISTEN)
        ControlCenter   794 demo    9u  IPv4 0x3faa919bbf7f1b45      0t0  TCP *:7000 (LISTEN)
        Python    89087 demo    3u  IPv4 0x1      0t0  TCP 127.0.0.1:8761 (LISTEN)
        Discord\\x20Helper 2230 demo 30u IPv6 0x2 0t0 TCP [::1]:6463 (LISTEN)
        """
        let ls = SecCheck.Listeners.parseLsof(out)
        #expect(ls.map(\.port) == [49182, 7000, 8761, 6463])
        #expect(ls[3] == .init(proc: "Discord Helper", addr: "::1", port: 6463))
        #expect(ls.filter(SecCheck.Listeners.external).map(\.proc) == ["rapportd", "ControlCenter"])
    }

    @Test("遠端存取只列出")
    func remote() {
        let ls = SecCheck.Listeners.parse(netstat)
        let r = SecCheck.remoteItem(ls, anydesk: "已安裝、沒在跑", tailscale: "執行中")
        #expect(r.level == .info && r.detail.contains("螢幕共享") && !r.detail.contains("SSH"))
    }

    @Test("修正按鈕：綠燈沒有；紅燈有；DNS 黃燈不給修正（用確認）")
    func fixes() {
        #expect(SecFixer.fix(for: SecCheck.fileVaultItem("FileVault is On.")) == nil)
        #expect(SecFixer.fix(for: SecCheck.fileVaultItem("FileVault is Off."))?.needsAdmin == false)
        let fw = SecFixer.fix(for: SecCheck.firewallItem(global: "Firewall is disabled.", stealth: ""))
        #expect(fw?.kind == .firewallOn && fw?.needsAdmin == true)
        #expect(SecFixer.fix(for: SecCheck.networkItem(now: [], base: nil)) == nil)
        let gk = SecFixer.fix(for: SecCheck.integrityItem(sip: "status: enabled.", gk: "assessments disabled"))
        #expect(gk?.kind == .gatekeeperOn)
    }

    @Test("改回基準：DNS 設回、多的代理關掉、基準沒手動 DNS 就改回自動")
    func revert() {
        let c = SecFixer.revertCommands(now: ["DNS[Wi-Fi]=6.6.6.6", "代理[HTTP]=evil:8080"], base: [], services: ["Wi-Fi", "Ethernet"])
        #expect(c.contains(["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "Empty"]))
        #expect(c.contains(["/usr/sbin/networksetup", "-setwebproxystate", "Ethernet", "off"]))
        #expect(!c.contains { $0.contains("-setdnsservers") && $0.contains("Ethernet") })
        let back = SecFixer.revertCommands(now: [], base: ["DNS[Wi-Fi]=1.1.1.1,8.8.8.8"], services: ["Wi-Fi"])
        #expect(back == [["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "1.1.1.1", "8.8.8.8"]])
        #expect(SecFixer.revertCommands(now: ["DNS[Wi-Fi]=1.1.1.1"], base: ["DNS[Wi-Fi]=1.1.1.1"], services: ["Wi-Fi"]).isEmpty)
    }

    @Test("引號：Wi-Fi 名字有單引號、雙引號也不會跑掉")
    func quoting() {
        #expect(SecFixer.shQuote("Demo’s iphone") == "'Demo’s iphone'")
        #expect(SecFixer.shQuote("a'b") == #"'a'\''b'"#)
        #expect(SecFixer.asQuote(#"x "y" \z"#) == #""x \"y\" \\z""#)
    }

    @Test("卡片摘要：綠燈只寫數量，黃紅燈附白話")
    func summary() {
        let r = SecReport(items: [SecCheck.fileVaultItem("FileVault is On."), SecCheck.wifiItem(rawSecurity: 0)], at: Date(), seconds: 1)
        #expect(r.cardSummary.hasPrefix("本機資安體檢：綠燈 1 項"))
        #expect(r.cardSummary.contains("🔴5. 目前 Wi-Fi 加密方式：沒加密的 Wi-Fi"))
        #expect(!r.cardSummary.contains("FileVault"))
    }
}
