import SwiftUI

// MARK: - 项目卡片视图
// 性能优化：卡片 body 仅读取 project 属性，不追踪任何全局 @Observable 状态
// 这样日志写入、面板开关等操作不会触发其他卡片的重算

struct ProjectCardView: View, Equatable {
    let project: Project
    let appState: AppState
    let isPinned: Bool

    @State private var showBuildOptions = false
    @State private var showTrashConfirm = false

    /// Equatable：仅当 project 数据或置顶状态变化时才重算此卡片
    static func == (lhs: ProjectCardView, rhs: ProjectCardView) -> Bool {
        lhs.project.id == rhs.project.id &&
        lhs.project.status == rhs.project.status &&
        lhs.project.name == rhs.project.name &&
        lhs.isPinned == rhs.isPinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            cardBody
            cardActions
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isPinned ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.06),
                    lineWidth: isPinned ? 1.5 : 1
                )
        )
    }

    // MARK: - 卡片头部

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Text(project.name)
                .font(.headline)
                .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.12))
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

                if project.hasNodeModules {
                    Text("node_modules")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color(red: 0.15, green: 0.55, blue: 0.25))
                }
            }

            if let branch = project.gitBranch {
                HStack(spacing: 4) {
                    Image("gitbranch")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.5))
                    Text(branch)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.5))
                .help(project.path.path)
            } else {
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if project.hasScripts {
                let scriptNames = project.scripts.keys.sorted().prefix(5)
                Text("Scripts: \(scriptNames.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.45))
                    .lineLimit(1)
            } else {
                Text("无可用 scripts")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 操作按钮栏

    private var cardActions: some View {
        HStack(spacing: 6) {
            if project.status == .running {
                ActionButton(icon: "stop.fill", label: "停止", tint: .red) {
                    Task { await appState.stopProject(project) }
                }
            } else if project.status.isBusy {
                ActionButton(icon: "hourglass", label: project.status.description, tint: .blue) {
                }
                .disabled(true)
            } else {
                ActionButton(icon: "play.fill", label: "运行", tint: .green) {
                    Task { await appState.startProject(project) }
                }
            }

            if project.scripts["build"] != nil || project.scripts["border"] != nil {
                ActionButton(icon: "hammer.fill", label: "构建", tint: .orange) {
                    showBuildOptions = true
                }
                .disabled(project.status.isBusy)
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

                if !appState.detectedEditors.isEmpty {
                    Menu("在编辑器中打开") {
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
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)

            Text(status.description)
                .font(.caption2)
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.5))
        }
    }
}

// MARK: - 框架标签

private struct FrameworkTag: View {
    let type: FrameworkType

    var body: some View {
        Image(type.svgFilename, bundle: .main)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .help(type.rawValue)
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
