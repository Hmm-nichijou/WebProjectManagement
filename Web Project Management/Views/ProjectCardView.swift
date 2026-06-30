import SwiftUI

// MARK: - 项目卡片视图
// 性能优化：卡片 body 仅读取 project 属性，不追踪任何全局 @Observable 状态
// 这样日志写入、面板开关等操作不会触发其他卡片的重算

struct ProjectCardView: View, Equatable {
    let project: Project
    let appState: AppState
    let isPinned: Bool
    let hasEditors: Bool
    let hbuilderxInfo: EditorInfo?
    let wechatDevToolsInfo: EditorInfo?

    @State private var showBuildOptions = false
    @State private var showTrashConfirm = false

    /// Equatable：仅当 project 数据或置顶状态变化时才重算此卡片
    static func == (lhs: ProjectCardView, rhs: ProjectCardView) -> Bool {
        lhs.project.id == rhs.project.id &&
        lhs.project.status == rhs.project.status &&
        lhs.project.name == rhs.project.name &&
        lhs.project.gitStatus == rhs.project.gitStatus &&
        lhs.project.hasNodeModules == rhs.project.hasNodeModules &&
        lhs.project.isEnriched == rhs.project.isEnriched &&
        lhs.isPinned == rhs.isPinned &&
        lhs.hasEditors == rhs.hasEditors &&
        lhs.hbuilderxInfo == rhs.hbuilderxInfo &&
        lhs.wechatDevToolsInfo == rhs.wechatDevToolsInfo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            cardBody
            cardActions
        }
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isPinned ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06),
                    lineWidth: isPinned ? 1.5 : 1
                )
        )
        .compositingGroup()
        .shadow(color: Color.primary.opacity(0.08), radius: 4, x: 0, y: 2)
    }

    // MARK: - 卡片头部

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(project.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            // 置顶按钮（悬停 + 点击效果）
            PinButton(isPinned: isPinned) {
                appState.togglePin(project)
            }

            StatusIndicator(status: project.status)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 卡片内容

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FrameworkTag(type: project.frameworkType)

                if let pm = project.packageManager {
                    PackageManagerTag(type: pm)
                }

                // node_modules 安装状态标签（仅已安装时显示）
                if project.hasNodeModules {
                    NodeModulesTag()
                }
            }

            if !project.isEnriched {
                HStack(spacing: 4) {
                    Image(systemName: "circle.dashed")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("加载中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let branch = project.gitBranch {
                HStack(spacing: 4) {
                    Image("gitbranch")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                    Text(branch)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)

                    // Git 状态指示（工作区干净时不显示）
                    if let gs = project.gitStatus, !(gs.isClean && !gs.hasUpstreamDiff) {
                        HStack(spacing: 8) {
                            if gs.modified > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "pencil.line")
                                    Text("\(gs.modified)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            }
                            if gs.untracked > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "questionmark")
                                    Text("\(gs.untracked)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.8))
                            }
                            if gs.ahead > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "arrow.up")
                                    Text("\(gs.ahead)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            }
                            if gs.behind > 0 {
                                HStack(spacing: 1) {
                                    Image(systemName: "arrow.down")
                                    Text("\(gs.behind)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            }
                        }
                    }
                }
                .help(gitStatusTooltip)
            } else {
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Git 状态 Tooltip

    private var gitStatusTooltip: String {
        var parts: [String] = [project.path.path]
        if let gs = project.gitStatus {
            var statusParts: [String] = []
            if gs.isClean { statusParts.append("工作区干净") }
            if gs.modified > 0 { statusParts.append("修改 \(gs.modified)") }
            if gs.added > 0 { statusParts.append("暂存 \(gs.added)") }
            if gs.untracked > 0 { statusParts.append("未跟踪 \(gs.untracked)") }
            if gs.ahead > 0 { statusParts.append("领先远程 \(gs.ahead) 个提交") }
            if gs.behind > 0 { statusParts.append("落后远程 \(gs.behind) 个提交") }
            parts.append(statusParts.joined(separator: "，"))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 操作按钮栏

    private var cardActions: some View {
        HStack(spacing: 6) {
            // unknown 和微信小程序项目不显示运行和构建按钮
            if project.frameworkType.supportsRunBuild {
                // 启停按钮：仅关注运行状态，不受构建状态影响
                if project.status == .running {
                    ActionButton(icon: "stop.fill", label: "停止", tint: .red) {
                        Task { await appState.stopProject(project) }
                    }
                } else {
                    ActionButton(icon: "play.fill", label: "运行", tint: .green) {
                        Task { await appState.startProject(project) }
                    }
                }

                // 构建按钮：忙碌时变为取消按钮
                if project.status.isBusy {
                    ActionButton(icon: "xmark.circle.fill", label: "取消构建", tint: .red) {
                        Task { await appState.stopProject(project) }
                    }
                } else if project.scripts["build"] != nil || project.scripts["border"] != nil {
                    ActionButton(icon: "hammer.fill", label: "构建", tint: .orange) {
                        showBuildOptions = true
                    }
                    .confirmationDialog("选择构建方式", isPresented: $showBuildOptions, titleVisibility: .visible) {
                        Button("快速构建") {
                            Task { await appState.buildProject(project) }
                        }
                        Button("全新构建") {
                            Task { await appState.cleanBuildProject(project) }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("全新构建会删除 node_modules 并重新安装依赖，耗时较长")
                    }
                }
            }

            Spacer()

            // 日志按钮：仅非空闲项目显示（不读取 logStore，避免追踪日志变化）
            if project.status != .idle {
                IconOnlyButton(
                    icon: "terminal",
                    tint: Color(red: 0.4, green: 0.4, blue: 0.45),
                    tooltip: "查看日志"
                ) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        appState.toggleLogPanel(for: project)
                    }
                }
            }

            // 更多操作
            Menu {
                Button {
                    appState.revealInFinder(project)
                } label: {
                    Label("在 Finder 中打开", systemImage: "folder")
                }

                if hasEditors
                    || (project.frameworkType.isUniApp && hbuilderxInfo != nil)
                    || (project.frameworkType == .wechatMiniProgram && wechatDevToolsInfo != nil) {
                    Menu("在编辑器中打开") {
                        // uni-app 项目在顶部显示 HBuilderX
                        if project.frameworkType.isUniApp, let hbuilderx = hbuilderxInfo {
                            Button {
                                appState.openInEditor(project, editor: hbuilderx)
                            } label: {
                                Label {
                                    Text(hbuilderx.displayName)
                                } icon: {
                                    hbuilderx.appIcon
                                }
                            }
                            Divider()
                        }
                        // 微信小程序项目在顶部显示微信开发者工具
                        if project.frameworkType == .wechatMiniProgram, let devtools = wechatDevToolsInfo {
                            Button {
                                appState.openInEditor(project, editor: devtools)
                            } label: {
                                Label {
                                    Text(devtools.displayName)
                                } icon: {
                                    devtools.appIcon
                                }
                            }
                            Divider()
                        }
                        ForEach(appState.detectedEditors) { editor in
                            Button {
                                appState.openInEditor(project, editor: editor)
                            } label: {
                                Label {
                                    Text(editor.displayName)
                                } icon: {
                                    editor.appIcon
                                }
                            }
                        }
                    }
                }

                Button {
                    appState.openInTerminal(project)
                } label: {
                    Label("在终端中打开", systemImage: "terminal")
                }


                Divider()

                Button {
                    Task { await appState.refreshProject(project) }
                } label: {
                    Label("刷新项目信息", systemImage: "arrow.clockwise.circle")
                }

                Button {
                    Task { await appState.reinstallProject(project) }
                } label: {
                    Label("重装依赖", systemImage: "arrow.clockwise")
                }
                .disabled(!FileManager.default.fileExists(atPath: project.path.appendingPathComponent("package.json").path))

                Divider()

                Button(role: .destructive) {
                    showTrashConfirm = true
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .confirmationDialog(
                "确认将「\(project.name)」移到废纸篓？此操作可在废纸篓中恢复。",
                isPresented: $showTrashConfirm,
                titleVisibility: .visible
            ) {
                Button("移到废纸篓", role: .destructive) {
                    Task { await appState.trashProject(project) }
                }
                Button("取消", role: .cancel) {}
            }
            .help("更多操作")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - 状态指示灯

private struct StatusIndicator: View {
    let status: ProjectStatus

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)

            Text(status.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 框架标签

private struct FrameworkTag: View {
    let type: FrameworkType

    var body: some View {
        if type != .unknown {
            Image(type.svgFilename, bundle: .main)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .help(type.rawValue)
        }
    }
}

// MARK: - 包管理器标签

private struct PackageManagerTag: View {
    let type: PackageManagerType

    var body: some View {
        Text(type.rawValue)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(type.tagBackgroundColor, in: Capsule())
            .foregroundStyle(type.tagTextColor)
    }
}

// MARK: - node_modules 标签

private struct NodeModulesTag: View {
    var body: some View {
        Text("node_modules")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.green)
    }
}

// MARK: - 操作按钮组件

private struct ActionButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(isHovering ? 0.18 : 0.10))
            )
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - 置顶按钮组件

private struct PinButton: View {
    let isPinned: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption)
                .foregroundStyle(
                    isPressed ? (isPinned ? Color.accentColor.opacity(0.5) : Color(red: 0.5, green: 0.5, blue: 0.55).opacity(0.5))
                    : isHovering ? (isPinned ? Color.accentColor : Color(red: 0.4, green: 0.4, blue: 0.45))
                    : (isPinned ? Color.accentColor : Color(red: 0.6, green: 0.6, blue: 0.65))
                )
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(isPressed ? 0.12 : (isHovering ? 0.08 : 0)))
                )
                .scaleEffect(isPressed ? 0.9 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
        .onHover { hovering in isHovering = hovering }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help(isPinned ? "取消置顶" : "置顶")
    }
}

// MARK: - 图标按钮组件

private struct IconOnlyButton: View {
    let icon: String
    let tint: Color
    let tooltip: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(isHovering ? tint : Color(red: 0.5, green: 0.5, blue: 0.55))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(isHovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .help(tooltip)
    }
}
