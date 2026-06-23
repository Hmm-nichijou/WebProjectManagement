import SwiftUI

// MARK: - 底部统一终端面板
// 显示在窗口底部，每次只展示一个项目的终端日志

struct BottomLogPanel: View {
    let project: Project
    let logStore: LogStore
    let appState: AppState

    @State private var displayText: String = ""
    @State private var isAutoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // 顶部分隔线
            Rectangle()
                .fill(Color.black.opacity(0.1))
                .frame(height: 1)

            // 面板头部
            HStack(spacing: 10) {
                Image(project.frameworkType.svgFilename, bundle: .main)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)

                Text(project.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.85, green: 0.87, blue: 0.85))

                // 状态标签
                StatusBadge(status: project.status)

                Spacer()

                // 自动滚动
                PanelIconButton(
                    icon: isAutoScroll ? "arrow.down.to.line.compact" : "arrow.down.to.line",
                    tooltip: isAutoScroll ? "自动滚动：开启" : "自动滚动：关闭",
                    tint: isAutoScroll ? Color(red: 0.35, green: 0.85, blue: 0.55) : Color(red: 0.55, green: 0.55, blue: 0.6)
                ) {
                    isAutoScroll.toggle()
                }

                // 清除日志
                PanelIconButton(icon: "trash", tooltip: "清除日志") {
                    displayText = ""
                    logStore.clear(for: project.path.path)
                }

                // 关闭面板
                PanelIconButton(icon: "xmark", tooltip: "关闭面板") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.logViewingProjectID = nil
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(red: 0.16, green: 0.17, blue: 0.19))

            // 日志内容（深色终端风格）
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText.isEmpty ? "等待输出..." : displayText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(displayText.isEmpty ? Color.gray : Color(red: 0.88, green: 0.9, blue: 0.88))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)

                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
                .onChange(of: displayText) { _, _ in
                    if isAutoScroll {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 240)
        .background(
            Color(red: 0.11, green: 0.12, blue: 0.14)
                .padding(.bottom, -20)
        )
        .task(id: project.id) {
            let path = project.path.path
            displayText = logStore.log(for: path)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let current = logStore.log(for: path)
                if current != displayText {
                    displayText = current
                }
            }
        }
    }
}

// MARK: - 状态小标签

private struct StatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.description)
                .font(.system(size: 10))
                .foregroundStyle(Color.gray)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

// MARK: - 面板内小图标按钮

private struct PanelIconButton: View {
    let icon: String
    let tooltip: String
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint.opacity(isPressed ? 0.5 : 1.0))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(isPressed ? 0.2 : (isHovering ? 0.12 : 0)))
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
        .help(tooltip)
    }
}
