import SwiftUI

// MARK: - 项目运行状态

enum ProjectStatus: Sendable {
    case idle         // 空闲/停止
    case running      // 正在运行
    case installing   // 安装依赖中
    case building     // 构建中
    case compressing  // 压缩中

    /// 筛选图标
    nonisolated var iconName: String {
        switch self {
        case .idle: return "circle"
        case .running: return "play.circle.fill"
        case .installing: return "arrow.down.circle.fill"
        case .building: return "hammer.fill"
        case .compressing: return "archivebox.fill"
        }
    }

    /// 状态颜色（筛选图标和状态指示灯共用）
    nonisolated var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .green
        case .installing, .building, .compressing: return .blue
        }
    }

    /// 状态描述文本
    nonisolated var description: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .installing: return "安装中"
        case .building: return "构建中"
        case .compressing: return "压缩中"
        }
    }

    /// 是否处于忙碌状态（安装/构建/压缩中的任意一种）
    nonisolated var isBusy: Bool {
        switch self {
        case .installing, .building, .compressing: return true
        default: return false
        }
    }
}
