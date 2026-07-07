import SwiftUI

// MARK: - 窗口背景色

@MainActor
struct AppBackgroundView: View {
    var body: some View {
        Color(.windowBackgroundColor)
            .ignoresSafeArea()
    }
}
