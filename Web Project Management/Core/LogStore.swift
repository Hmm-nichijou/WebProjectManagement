import SwiftUI

// MARK: - 独立日志存储 (@Observable)
// 将日志从 projects 数组中分离，避免日志追加触发整个项目网格重算
// 每个项目的日志更新仅影响订阅了该项目的 LogDrawerView

@MainActor
@Observable
final class LogStore {

    /// 日志内容，key 为项目路径字符串
    private var logs: [String: String] = [:]

    /// 每个项目的"版本号"，递增时仅触发订阅了该 key 的视图重算
    private var generations: [String: Int] = [:]

    /// 追加日志内容
    func append(_ text: String, for path: String) {
        logs[path, default: ""] += text
        generations[path, default: 0] += 1
    }

    /// 清空指定项目的日志
    func clear(for path: String) {
        logs[path] = ""
        generations[path, default: 0] += 1
    }

    /// 获取指定项目的当前日志（视图读取时自动追踪 generation）
    func log(for path: String) -> String {
        _ = generations[path] // 触发 @Observable 追踪
        return logs[path] ?? ""
    }
}
