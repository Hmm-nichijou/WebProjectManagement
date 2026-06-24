import Foundation

// MARK: - 日志条目
// 每条日志为一个独立结构体，携带稳定行号用于 LazyVStack 的 ForEach 标识

struct LogEntry: Identifiable, Sendable {
    let id: Int       // 全局递增行号，作为稳定标识
    let text: String
}

// MARK: - 独立日志存储 (@Observable)
// 将日志从 projects 数组中分离，避免日志追加触发整个项目网格重算
// 使用行缓冲区替代单字符串拼接，解决大量日志时的 O(n) 拷贝开销
// 自动裁剪超出上限的旧行，防止内存无限增长

@MainActor
@Observable
final class LogStore {

    /// 单项目日志上限（行）
    private static let maxLines = 2000

    /// 裁剪后保留的行数（避免频繁裁剪）
    private static let trimToLines = 1500

    /// 日志条目，key 为项目路径字符串
    private var logEntries: [String: [LogEntry]] = [:]

    /// 全局行号计数器（递增，用于 LogEntry.id）
    private var lineCounter: Int = 0

    /// 每个项目的"版本号"，递增时仅触发订阅了该 key 的视图重算
    private var generations: [String: Int] = [:]

    /// 追加日志文本（自动按换行拆分为条目）
    func append(_ text: String, for path: String) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }

        var entries = logEntries[path] ?? []
        entries.reserveCapacity(entries.count + newLines.count)

        for line in newLines {
            entries.append(LogEntry(id: lineCounter, text: line))
            lineCounter += 1
        }

        // 超出上限时裁剪旧行
        if entries.count > Self.maxLines {
            let removeCount = entries.count - Self.trimToLines
            entries.removeFirst(removeCount)
        }

        logEntries[path] = entries
        generations[path, default: 0] += 1
    }

    /// 清空指定项目的日志
    func clear(for path: String) {
        logEntries[path] = []
        generations[path, default: 0] += 1
    }

    /// 获取指定项目的日志条目数组（供 LazyVStack 渲染）
    func entries(for path: String) -> [LogEntry] {
        _ = generations[path] // 触发 @Observable 追踪
        return logEntries[path] ?? []
    }
}
