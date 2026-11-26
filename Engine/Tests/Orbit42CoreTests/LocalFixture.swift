import Foundation
@testable import Orbit42Core

/// 測試用的本機設定（LocalConfig）：不管這台電腦有沒有 local.json，測試都讀這份（假名）
enum LocalFixture {
    static let config = LocalConfig(owner: "小明", headsetProjects: ["ProjectC", "ProjectE"], privateDataRepos: ["ProjectC"],
                                    winHosts: ["winbox"], noKickoffRepos: ["ProjectC"])
    static let url: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-local-\(getpid()).json")
        try? JSONEncoder().encode(config).write(to: u, options: .atomic)
        return u
    }()
    static func use() { setenv("ORBIT_LOCAL_CONFIG", url.path, 1) }
}
