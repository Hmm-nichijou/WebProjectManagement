import Foundation
import SwiftUI

// MARK: - Git 状态

struct GitStatus: Sendable, Equatable {
    let modified: Int     // 修改的文件数
    let added: Int        // 暂存的文件数
    let untracked: Int    // 未跟踪的文件数
    let ahead: Int        // 领先远程的提交数
    let behind: Int       // 落后远程的提交数

    /// 工作区是否干净（无修改、无暂存、无未跟踪）
    nonisolated var isClean: Bool {
        modified == 0 && added == 0 && untracked == 0
    }

    /// 是否有未同步的提交
    nonisolated var hasUpstreamDiff: Bool {
        ahead > 0 || behind > 0
    }
}

// MARK: - 包管理器类型

enum PackageManagerType: String, Sendable {
    case npm
    case pnpm
    case yarn

    /// 对应的可执行文件名
    nonisolated var executable: String { rawValue }

    /// 安装命令
    nonisolated var installCommand: String { "install" }

    /// 标签文字颜色
    nonisolated var tagTextColor: Color { .white }

    /// 标签背景颜色
    nonisolated var tagBackgroundColor: Color {
        switch self {
        case .npm: return Color(red: 0.918, green: 0.125, blue: 0.224)    // #ea2039
        case .pnpm: return Color(red: 0.965, green: 0.573, blue: 0.125)   // #f69220
        case .yarn: return Color(red: 0.165, green: 0.545, blue: 0.820)
        }
    }
}

// MARK: - Web 项目模型

struct Project: Identifiable, Sendable {
    let id: UUID
    let name: String
    let path: URL
    let frameworkType: FrameworkType
    let packageManager: PackageManagerType?
    let scripts: [String: String]
    let gitBranch: String?
    let gitStatus: GitStatus?
    let nodeModulesSize: Int64
    let distSize: Int64
    let distZipSize: Int64

    /// 当前运行状态
    var status: ProjectStatus = .idle
    /// 磁盘占用总计（node_modules + dist + dist.zip）
    nonisolated var totalDiskUsage: Int64 {
        nodeModulesSize + distSize + distZipSize
    }

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        frameworkType: FrameworkType,
        packageManager: PackageManagerType? = nil,
        scripts: [String: String] = [:],
        gitBranch: String? = nil,
        gitStatus: GitStatus? = nil,
        nodeModulesSize: Int64 = 0,
        distSize: Int64 = 0,
        distZipSize: Int64 = 0,
        status: ProjectStatus = .idle
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.frameworkType = frameworkType
        self.packageManager = packageManager
        self.scripts = scripts
        self.gitBranch = gitBranch
        self.gitStatus = gitStatus
        self.nodeModulesSize = nodeModulesSize
        self.distSize = distSize
        self.distZipSize = distZipSize
        self.status = status
    }
}
