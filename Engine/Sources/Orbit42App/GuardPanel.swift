import AppKit
import SwiftUI
import Orbit42Core

// 保全面板：Wi-Fi 裝置、push 守門「放行一次」、定時巡邏（11-26 起在設定窗「保全」分頁）

private struct GuardBadge: View {
    let level: GuardLevel
    var body: some View {
        Text(level.title).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(level.color.opacity(0.25), in: Capsule())
            .overlay(Capsule().strokeBorder(level.color.opacity(0.8)))
    }
}

/// 保全面板裡的 push 守門：最近 24 小時檢查／擋下幾次＋最近幾筆（PushGuard，10-22）
private struct PushGuardSection: View {
    let status: GuardStatus
    @State private var allowed: Set<String> = []     // 這次開面板按過放行的（dir+head+被擋時間）
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Push 守門").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(status.pushChecked == 0 ? "24 小時內沒有 push" : "24 小時內 \(status.pushChecked) 次・擋下 \(status.pushBlocked) 次")
                    .font(.caption).foregroundStyle(status.pushBlocked > 0 ? .orange : .secondary).monospacedDigit()
            }
            ForEach(Array(status.pushRecent.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(e.verdict == .block ? "擋下" : e.verdict == .warn ? "提醒" : "放行").font(.caption.weight(.semibold))
                        .foregroundStyle(e.verdict == .block ? Color.red : e.verdict == .warn ? Color.orange : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(e.repo)\(e.refs.isEmpty ? "" : "・" + e.refs.joined(separator: ","))・\(e.commits) 個 commit" + (e.name.map { "・\($0)" } ?? ""))
                            .font(.callout).lineLimit(1)
                        if !e.reasons.isEmpty {
                            Text(e.reasons.joined(separator: "；")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 4)
                    if e.verdict == .block, let h = e.head, !h.isEmpty, Date().timeIntervalSince(e.at) < 3600 {
                        // 記號要帶被擋的時間：同一個 HEAD 放行用掉後又被擋（例如 git 自己拒推、重推），新的那筆要能再按（11-03）
                        let k = e.dir + h + "\(e.at.timeIntervalSince1970)"
                        Button(allowed.contains(k) ? "已放行" : "放行一次") {
                            guard !AppTest.mode else { allowed.insert(k); return }   // 測試視窗不寫檔
                            PushGuard.allow(e); allowed.insert(k)
                        }
                        .controlSize(.small).disabled(allowed.contains(k))
                        .help("這個 repo、這個 HEAD，30 分鐘內 AI 再推一次就不擋（用掉就失效）")
                    }
                    Text(e.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("AI 跑 git push 前保全會先檢查：ghosts、old-history、force push main、金鑰、私人資料直接擋；關鍵字在 board/guard/keywords.txt。誤擋就按「放行一次」")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 點了保全：Wi-Fi 狀態、要注意的裝置、立即掃描、定時巡邏（資料來自 wifiwatch）
struct GuardCard: View {
    let status: GuardStatus
    let scanning: Bool
    @Binding var patrol: Bool
    let onScan: () -> Void
    var onClose: (() -> Void)? = nil
    @State private var showOnline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("保全").font(.headline)
                GuardBadge(level: status.level)
                Spacer(minLength: 8)
                if let onClose {
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("關閉").keyboardShortcut(.cancelAction)
                }
            }
            Text(status.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("上次掃描").foregroundStyle(.secondary)
                    if let t = status.lastScan {
                        Text("\(t.formatted(date: .abbreviated, time: .shortened))（\(t.formatted(.relative(presentation: .named)))）")
                            .foregroundStyle(status.stale ? .orange : .primary)
                    } else {
                        Text("還沒掃描過").foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("在線裝置").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("\(status.onlineCount) 台（名冊共 \(status.knownCount) 台）").monospacedDigit()
                        if !status.onlineDevices.isEmpty {
                            Button(showOnline ? "收起" : "列出全部") { showOnline.toggle() }
                                .buttonStyle(.link).help("列出上次掃描在線的每一台裝置")
                        }
                    }
                }
            }
            .font(.callout)
            if showOnline { OnlineDeviceList(devices: status.onlineDevices) }
            if status.flagged.isEmpty {
                Label(status.hasData ? "沒有陌生或沒命名的裝置" : "還沒有名冊（wifiwatch 沒跑過）", systemImage: status.hasData ? "checkmark.shield" : "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("要注意的裝置（\(status.flagged.count)）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(status.flagged, id: \.mac) { d in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(d.online ? Color.green : Color.gray.opacity(0.5)).frame(width: 7, height: 7)
                                    .help(d.online ? "上次掃描時在線" : "上次掃描時不在")
                                Text(d.kind.title).font(.caption.weight(.semibold))
                                    .foregroundStyle(d.kind == .unconfirmed ? .orange : .red)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text([d.ip ?? (d.privacyOnly ? "只有 IPv6（多半是家裡手機的隱私位址）" : nil), d.vendor, d.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                                        .font(.callout).lineLimit(1)
                                    Text(d.mac + (d.firstSeen.map { "・第一次看到 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                        .font(.caption).monospaced().foregroundStyle(.secondary).lineLimit(1)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
            Divider()
            PushGuardSection(status: status)
            Divider()
            HStack(spacing: 10) {
                Toggle("定時巡邏", isOn: $patrol).toggleStyle(.switch).controlSize(.small)
                    .help("開著時，常駐程式每 30 分鐘最多掃一次（只在 Orbit42 裡有效）")
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button(scanning ? "掃描中⋯" : "立即掃描", action: onScan)
                    .disabled(scanning)
                    .help("跑 wifiwatch：ping 整個網段、讀 ARP，約數十秒；有新裝置會記進名冊")
            }
            Text("命名裝置：wifiwatch.sh --label <MAC> <名字>").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(minWidth: 460, maxWidth: .infinity, alignment: .leading)
    }
}

/// 保全面板「列出全部」：上次掃描在線的每一台（10-24 Kang：在線 20 台要看得到是哪些）
private struct OnlineDeviceList: View {
    let devices: [GuardDevice]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(devices, id: \.mac) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(d.kind == .named ? Color.green : d.kind == .unconfirmed ? Color.orange : Color.red).frame(width: 7, height: 7)
                            .help(d.kind.title)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.label ?? d.hostname ?? "（沒命名）").font(.callout).lineLimit(1)
                                .foregroundStyle(d.label == nil ? .secondary : .primary)
                            Text([d.ip ?? "只有 IPv6", d.vendor, d.mac].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }
}

extension GuardLevel {
    var color: Color { switch self { case .normal: .green; case .notice: .orange; case .alert: .red } }
}

extension GuardDevice.Kind {
    var title: String {
        switch self {
        case .new: "新裝置"
        case .unnamed: "沒命名"
        case .unconfirmed: "待確認"
        case .named: "已命名"
        }
    }
}
