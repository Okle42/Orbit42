import Foundation
import Testing
@testable import Orbit42Core

// 11-28 T1128183531：組員只交 commit、秘書一件一件裝（守則文字）
@Suite("裝 App 的流程守則：組員只交 commit、秘書一件一件裝")
struct InstallFlowTests {
    @Test("組員開工看到的提示：只交 commit、不打包重開 push、只在自己卡片問、一個專案、300k 交接")
    func member() {
        let b = CardRules.brief(orbit: "/x/orbit")
        for s in ["只交 commit", "不要自己打包", "重開", "push", "回報給秘書", "只在你自己的卡片問", "一次只做一個專案", "300k"] {
            #expect(b.contains(s), "\(s)")
        }
        #expect(b.contains("你是秘書就看 orbit captain"))          // 秘書不受這段限制
    }

    @Test("秘書守則：測過馬上併 main、push、打包、重開，一件一件、不批次；打包前檢查與強制原因")
    func captain() {
        let m = Captain.manual(orbit: "orbit")
        for s in ["一件一件來，不批次", "組員只交 commit", "馬上併進主資料夾的 main", "不要攢著幾件一起裝", "ORBIT_BUILD_FORCE", "倒退", "300k", "一個組員一次只做一個專案"] {
            #expect(m.contains(s), "\(s)")
        }
        // 舊的「只在組員卡片問」那條還在
        #expect(m.contains("派出去的事只在組員卡片問"))
    }

    @Test("派工單全文也提醒只交 commit")
    func dispatch() {
        let t = CaptainTask(id: "T1", from: "C", to: "組員甲", text: "修一個按鈕")
        #expect(Captain.message(t, orbit: "orbit").contains("只交 commit"))
    }
}
