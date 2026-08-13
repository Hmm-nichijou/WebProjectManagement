import SwiftUI

// MARK: - 窗口背景（Liquid Glass 毛玻璃，macOS 26+）
// 使用 .glassEffect 实现 Apple 官方 App 侧边栏同款的液态玻璃质感，
// 自动适配浅色/深色外观，并随窗口后的桌面壁纸产生折射与磨砂效果。

struct AppBackgroundView: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .glassEffect(in: Rectangle())
            .ignoresSafeArea()
    }
}
