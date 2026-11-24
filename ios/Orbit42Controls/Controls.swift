import WidgetKit
import SwiftUI
import AppIntents

/// 11-24 Keng：控制中心／鎖定畫面的 Orbit42 按鈕：按一下打開 Orbit42 開始聽，說完交給 Mac 上的智能體
@main
struct Orbit42ControlsBundle: WidgetBundle {
    var body: some Widget { ListenControl() }
}

struct ListenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ai.okle42.orbit42.phone.listen") {
            ControlWidgetButton(action: ListenIntent()) {
                Label("Orbit42", systemImage: "waveform")
            }
        }
        .displayName("Orbit42 說話")
        .description("打開 Orbit42 開始聽，說完交給 Mac 上的智能體。")
    }
}
