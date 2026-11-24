import SwiftUI
import Speech
import AVFoundation

/// 11-24 Keng：手機說話給 Mac 上的智能體（跟在 Mac 上按住智能體講話同一條路：簡單的它自己答，答不了交給秘書）。
/// iPhone 內建語音辨識（中文），停頓 1.6 秒就自動結束、送到 Mac 的 /api/say。動作按鈕／控制中心按鈕也是開這個。
@MainActor
final class VoiceInput: ObservableObject {
    static let shared = VoiceInput()
    @Published var listening = false
    @Published var text = ""
    @Published var status: String?          // 送出結果（幾秒後自己消失）
    var link: MacLink?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?

    func toggle() { listening ? finish() : start() }

    func start() {
        guard !listening else { return }
        guard link != nil else { return flash("還沒連到 Mac") }
        SFSpeechRecognizer.requestAuthorization { st in
            Task { @MainActor in
                guard st == .authorized else { return self.flash("要在「設定 › Orbit42」打開語音辨識") }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in ok ? self.begin() : self.flash("要在「設定 › Orbit42」打開麥克風") }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return flash("語音辨識現在不能用") }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .measurement, options: .duckOthers)
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            let e = AVAudioEngine(), r = SFSpeechAudioBufferRecognitionRequest()
            r.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }      // 能在手機上辨識就不上傳 Apple
            let input = e.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in r.append(buf) }
            e.prepare(); try e.start()
            engine = e; request = r; text = ""; status = nil; listening = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            task = recognizer.recognitionTask(with: r) { [weak self] res, err in
                Task { @MainActor in
                    guard let self, self.listening else { return }
                    if let res { self.text = res.bestTranscription.formattedString; self.armSilence(final: res.isFinal) }
                    if err != nil, res == nil { self.finish() }
                }
            }
            armSilence(final: false, first: true)
        } catch { stopAudio(); flash("麥克風開不起來：\(error.localizedDescription)") }
    }

    /// 停頓多久就結束：一開始給 5 秒想，講了之後停 1.6 秒
    private func armSilence(final: Bool, first: Bool = false) {
        silence?.cancel()
        if final { return finish() }
        let wait: Double = first ? 5 : 1.6
        silence = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self?.finish() }
        }
    }

    func finish() {
        guard listening else { return }
        listening = false; silence?.cancel()
        stopAudio()
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return flash("沒聽到，再按一次") }
        guard let link else { return }
        status = "送出中…"
        Task {
            do { try await OrbitAPI(link: link).say(said); flash("已交給智能體：\(said)") ; UINotificationFeedbackGenerator().notificationOccurred(.success) }
            catch { flash("沒送出：\(error.localizedDescription)") }
        }
    }

    private func stopAudio() {
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        engine = nil; request = nil; task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func flash(_ s: String) {
        status = s
        Task { try? await Task.sleep(for: .seconds(4)); if self.status == s { self.status = nil } }
    }
}

/// 球體分頁右下角的麥克風鈕＋聽的時候的字幕卡
struct VoiceOverlay: View {
    @ObservedObject var voice = VoiceInput.shared
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if voice.listening || voice.status != nil {
                Text(voice.listening ? (voice.text.isEmpty ? "我在聽⋯" : voice.text) : (voice.status ?? ""))
                    .font(.callout).foregroundStyle(voice.listening ? Color.okAccent : Color.okInk)
                    .padding(12).frame(maxWidth: 300, alignment: .leading)
                    .background(Color.okPaper.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.okInk.opacity(0.5)))
                    .transition(.opacity)
            }
            Button { voice.toggle() } label: {
                Image(systemName: voice.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(voice.listening ? Color.okPaper : Color.okMic)
                    .frame(width: 58, height: 58)
                    .background(voice.listening ? Color.okMic : Color.okPaper.opacity(0.9), in: Circle())
                    .overlay(Circle().stroke(Color.okMic, lineWidth: 1.5))
                    .symbolEffect(.variableColor.iterative, isActive: voice.listening)
            }
            .accessibilityLabel(voice.listening ? "說完了" : "對智能體說話")
        }
        .padding(.trailing, 18).padding(.bottom, 24)
        .animation(.easeOut(duration: 0.2), value: voice.listening)
    }
}
