import SwiftUI

// MARK: - 空状态引导视图
// 首次打开应用时显示的大面积虚线拖拽区域，引导用户选择或拖拽项目目录

struct EmptyStateView: View {
    let onSelectDirectory: () -> Void
    let onDropDirectory: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // 静态图标（无动画，避免窗口切换时的性能开销）
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.5))

            // 引导文本
            VStack(spacing: 8) {
                Text("拖拽你的前端项目集目录到这里")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0.3, green: 0.3, blue: 0.35))

                Text("或点击下方按钮手动选择")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.55))
            }

            // 选择目录按钮
            Button(action: onSelectDirectory) {
                Label("选择目录", systemImage: "folder")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // 大面积虚线拖拽区域
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2.5, dash: [12, 8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
                .padding(48)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let url = urls.first {
                onDropDirectory(url)
                return true
            }
            return false
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

// MARK: - 虚线边框样式扩展

extension Shape {
    func strokeBorder(_ color: Color, style: StrokeStyle) -> some View {
        self.stroke(style: style)
            .foregroundStyle(color)
    }
}
