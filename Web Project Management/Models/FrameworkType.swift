import Foundation
import SwiftUI

// MARK: - 前端框架类型

enum FrameworkType: String, Sendable, CaseIterable {
    case vue = "Vue"
    case react = "React"
    case angular = "Angular"
    case htmlStatic = "HTML"
    case unknown = "Unknown"

    /// 本地 SVG 图标文件名（对应 Assets 资源目录）
    nonisolated var svgFilename: String {
        switch self {
        case .vue: return "vue"
        case .react: return "react"
        case .angular: return "angular"
        case .htmlStatic: return "html"
        case .unknown: return "unknown"
        }
    }

    /// 框架标识色（用于筛选标签等 UI 高亮）
    nonisolated var accentColor: Color {
        switch self {
        case .vue: return Color(red: 0.259, green: 0.722, blue: 0.514)       // #42b883
        case .react: return Color(red: 0.031, green: 0.494, blue: 0.643)    // #087ea4
        case .angular: return Color(red: 0.522, green: 0.078, blue: 0.961)  // #8514f5
        case .htmlStatic: return Color(red: 0.894, green: 0.302, blue: 0.149) // #E44D26
        case .unknown: return .gray
        }
    }
}
