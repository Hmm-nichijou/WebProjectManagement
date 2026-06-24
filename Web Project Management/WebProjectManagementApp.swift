import SwiftUI

// MARK: - Web Project Management 应用入口

@main
struct WebProjectManagementApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 720, minHeight: 500)
                .preferredColorScheme(appState.themeMode.colorScheme)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // 自定义菜单项
            CommandGroup(replacing: .newItem) {
                Button("添加项目...") {
                    appState.showAddProject = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("选择项目目录...") {
                    appState.selectDirectory()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("刷新扫描") {
                    Task { await appState.scanProjects() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.rootDirectory == nil)
            }
        }
    }
}
