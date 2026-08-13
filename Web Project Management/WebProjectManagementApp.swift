import SwiftUI
import AppKit

// MARK: - Web Project Management 应用入口

@main
struct WebProjectManagementApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 720, minHeight: 500)
                .preferredColorScheme(appState.themeMode.colorScheme)
                .background(WindowFrameAutosaver())
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

// MARK: - 窗口尺寸持久化
// SwiftUI 的 WindowGroup 不会自动持久化窗口框架（尺寸/位置），
// NSWindow.frameAutosaveName 在 WindowGroup 下因窗口重建会有名称冲突，
// 改用手动 UserDefaults + 通知监听方式保存和恢复窗口框架。

private struct WindowFrameAutosaver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowFrameAutosaverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowFrameAutosaverView: NSView {
    private let frameKey = "MainWindowFrame"
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // 视图从窗口移除时清理观察者
        if window == nil {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            return
        }

        guard let window = window else { return }

        // 恢复上次保存的窗口框架（校验尺寸不小于最小值）
        if let frameString = UserDefaults.standard.string(forKey: frameKey) {
            let frame = NSRectFromString(frameString)
            if frame.width >= 720 && frame.height >= 500 {
                window.setFrame(frame, display: true)
            }
        }

        // 监听窗口移动和缩放，自动保存框架
        let center = NotificationCenter.default
        let key = frameKey

        observers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let win = notification.object as? NSWindow else { return }
            // 通知闭包是 @Sendable，但 queue: .main 确保在主线程执行
            // 通过 MainActor.assumeIsolated 进入主 actor 上下文访问 main actor 隔离的 frame
            MainActor.assumeIsolated {
                UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: key)
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let win = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: key)
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
