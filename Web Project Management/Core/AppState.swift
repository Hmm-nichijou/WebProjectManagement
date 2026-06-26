import SwiftUI
import AppKit

// MARK: - 主题模式

enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - 编辑器信息

struct EditorInfo: Identifiable, Sendable, Equatable {
    let id: String            // bundle ID
    let displayName: String   // 从 .app bundle 获取的实际显示名称
    let appURL: URL           // .app 应用路径

    /// 从系统获取应用图标
    @MainActor var appIcon: Image {
        let nsImage = NSWorkspace.shared.icon(forFile: appURL.path)
        nsImage.size = NSSize(width: 16, height: 16)
        return Image(nsImage: nsImage)
    }

    static func == (lhs: EditorInfo, rhs: EditorInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 全局应用状态 (@Observable)
// 管理项目集、目录选择、扫描和进程操作
// 日志存储在独立的 LogStore 中，避免日志更新触发整个项目网格重算

@MainActor
@Observable
final class AppState {

    /// 用户选择的项目集根目录
    var rootDirectory: URL?

    /// 扫描到的项目列表
    var projects: [Project] = []

    /// 排序后的项目列表（置顶优先，同组内按名称排序）
    var sortedProjects: [Project] {
        projects.sorted { a, b in
            let aPinned = pinnedProjectPaths.contains(a.path.path)
            let bPinned = pinnedProjectPaths.contains(b.path.path)
            if aPinned != bPinned { return aPinned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// 是否正在扫描
    var isScanning: Bool = false

    /// 是否正在执行批量操作（删除构建/依赖）
    var isBatchOperating: Bool = false

    /// Toast 通知消息（非 nil 时自动显示并定时消失）
    var toastMessage: String? = nil

    /// 主题模式（浅色/深色/跟随系统）
    var themeMode: ThemeMode = .system {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: savedThemeKey)
        }
    }

    /// 是否为首次启动（无已保存目录）
    var isFirstLaunch: Bool = true

    /// 进程管理器（actor，确保并发安全）
    let processManager = ProjectProcessManager()

    /// 独立日志存储（日志更新不触发项目网格重算）
    let logStore = LogStore()

    /// 当前在底部面板查看日志的项目 ID（nil 表示面板关闭）
    var logViewingProjectID: UUID?

    /// 是否显示添加项目弹窗
    var showAddProject: Bool = false

    /// 活跃日志流缓存
    private var logStreams: [String: AsyncStream<String>] = [:]

    /// 云盘网站 URL（构建完成后自动打开）
    var cloudDriveURL: String = ""

    /// 置顶的项目路径集合（使用绝对路径而非 UUID，确保重新扫描后置顶状态不丢失）
    var pinnedProjectPaths: Set<String> = []

    /// 系统检测到的已安装编辑器
    var detectedEditors: [EditorInfo] = []

    /// HBuilderX 编辑器信息（仅 uniapp 项目使用）
    var hbuilderxInfo: EditorInfo? = nil

    /// 微信开发者工具信息（仅微信小程序项目使用）
    var wechatDevToolsInfo: EditorInfo? = nil

    /// 需要检测的编辑器 bundle ID 列表
    private static let editorBundleIDs = [
        "com.microsoft.VSCode",
        "com.jetbrains.WebStorm",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.sublimetext.4",
        "com.panic.Nova",
    ]

    /// HBuilderX bundle ID 列表
    private static let hbuilderxBundleIDs = [
        "io.dcloud.HBuilderX",
        "io.dcloud.HBuilderXAlpha",
    ]

    /// 微信开发者工具 bundle ID 列表
    private static let wechatDevToolsBundleIDs = [
        "com.tencent.webplusdevtools",
    ]

    // MARK: - UserDefaults 持久化键名
    private let savedPathKey = "savedRootDirectory"
    private let savedCloudDriveKey = "savedCloudDriveURL"
    private let savedPinnedKey = "savedPinnedProjectIDs"
    private let savedThemeKey = "savedThemeMode"

    // MARK: - 初始化

    init() {
        loadSavedDirectory()
        cloudDriveURL = UserDefaults.standard.string(forKey: savedCloudDriveKey) ?? ""
        if let pinnedData = UserDefaults.standard.data(forKey: savedPinnedKey),
           let pinned = try? JSONDecoder().decode(Set<String>.self, from: pinnedData) {
            pinnedProjectPaths = pinned
        }
        if let themeStr = UserDefaults.standard.string(forKey: savedThemeKey),
           let mode = ThemeMode(rawValue: themeStr) {
            themeMode = mode
        }
        Task { await detectEditors() }
    }

    /// 保存云盘网站 URL 到 UserDefaults
    func saveCloudDriveURL(_ url: String) {
        cloudDriveURL = url
        UserDefaults.standard.set(url, forKey: savedCloudDriveKey)
    }

    // MARK: - 目录管理

    /// 加载已保存的目录路径
    private func loadSavedDirectory() {
        if let path = UserDefaults.standard.string(forKey: savedPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                rootDirectory = url
                isFirstLaunch = false
                Task { await scanProjects() }
            }
        }
    }

    /// 设置新的项目集根目录
    func setRootDirectory(_ url: URL) {
        rootDirectory = url
        isFirstLaunch = false
        UserDefaults.standard.set(url.path, forKey: savedPathKey)
        Task { await scanProjects() }
    }

    /// 显示目录选择面板
    func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择你的前端项目集根目录"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            setRootDirectory(url)
        }
    }

    // MARK: - 项目扫描

    /// 扫描根目录下的所有 Web 项目
    func scanProjects() async {
        guard let root = rootDirectory else { return }
        isScanning = true
        defer { isScanning = false }

        let scanner = ProjectScanner()
        do {
            projects = try await scanner.scan(rootURL: root)
        } catch {
            print("扫描失败: \(error)")
        }
    }

    /// 刷新单个项目（保留运行状态）
    func refreshProject(_ project: Project) async {
        let scanner = ProjectScanner()
        let currentStatus = project.status
        do {
            let refreshed = try await scanner.scanSingle(projectURL: project.path)
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                var updated = refreshed
                updated.status = currentStatus
                projects[index] = updated
            }
        } catch {
            print("刷新项目失败: \(error)")
        }
    }

    // MARK: - 项目置顶

    /// 判断项目是否被置顶
    func isPinned(_ project: Project) -> Bool {
        pinnedProjectPaths.contains(project.path.path)
    }

    /// 切换项目的置顶状态
    func togglePin(_ project: Project) {
        let path = project.path.path
        if pinnedProjectPaths.contains(path) {
            pinnedProjectPaths.remove(path)
        } else {
            pinnedProjectPaths.insert(path)
        }
        if let data = try? JSONEncoder().encode(pinnedProjectPaths) {
            UserDefaults.standard.set(data, forKey: savedPinnedKey)
        }
    }

    // MARK: - Git 克隆

    /// 克隆 Git 仓库到根目录，完成后重新扫描并打开日志面板
    @discardableResult
    func cloneProject(gitURL: String) async -> String? {
        guard let root = rootDirectory else { return "未设置项目根目录" }

        // 从 URL 提取项目名
        let name = gitURL
            .components(separatedBy: "/").last?
            .replacingOccurrences(of: ".git", with: "") ?? "project"

        let targetPath = root.appendingPathComponent(name)

        // 如果目录已存在，报错
        if FileManager.default.fileExists(atPath: targetPath.path) {
            return "目录 \(name) 已存在"
        }

        let path = targetPath.path
        logStore.clear(for: path)

        // 创建日志流
        let stream = AsyncStream<String> { continuation in
            continuation.yield("[克隆] git clone \(gitURL)\n")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["clone", gitURL, targetPath.path]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let readPipe = { (pipe: Pipe) in
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    continuation.yield(text)
                }
            }
            readPipe(outputPipe)
            readPipe(errorPipe)

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.yield("\n[完成] 克隆成功 ✓\n")
                } else {
                    continuation.yield("\n[错误] 克隆失败 (code: \(proc.terminationStatus))\n")
                }
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield("\n[错误] \(error.localizedDescription)\n")
                continuation.finish()
            }
        }

        logStreams[path] = stream

        // 后台消费日志写入 LogStore
        Task { [weak self] in
            for await chunk in stream {
                self?.logStore.append(chunk, for: path)
            }
        }

        // 等待克隆完成（通过日志流结束判断）
        for await _ in logStreams[path]! {}

        // 重新扫描项目
        await scanProjects()

        // 找到新项目并打开日志面板
        if let newProject = projects.first(where: { $0.path.path == path }) {
            logViewingProjectID = newProject.id
        }

        return nil
    }

    // MARK: - 进程操作

    /// 启动开发服务器
    func startProject(_ project: Project, script: String = "dev") async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }

        let path = project.path.path
        logStore.clear(for: path)

        let stream = await processManager.start(project: project, script: script)
        logStreams[path] = stream

        projects[index].status = .running
        logViewingProjectID = project.id

        // 后台消费日志流 → 写入 LogStore（不触发 projects 数组变化）
        Task { [weak self] in
            for await chunk in stream {
                self?.logStore.append(chunk, for: path)
            }
        }
    }

    /// 停止项目进程
    func stopProject(_ project: Project) async {
        await processManager.stop(projectPath: project.path)
        logStreams.removeValue(forKey: project.path.path)
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].status = .idle
        }
        // 停止时自动关闭该项目的日志面板
        if logViewingProjectID == project.id {
            logViewingProjectID = nil
        }
    }

    /// 执行构建
    func buildProject(_ project: Project) async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].status = .building

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.build(
            project: project,
            cloudDriveURL: cloudDriveURL.isEmpty ? nil : cloudDriveURL,
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if let idx = self.projects.firstIndex(where: { $0.id == project.id }) {
                        self.projects[idx].status = status
                    }
                }
            }
        )
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream {
                self?.logStore.append(chunk, for: path)
            }
            guard let self else { return }
            await self.processManager.stop(projectPath: project.path)
            if let idx = self.projects.firstIndex(where: { $0.id == project.id }) {
                self.projects[idx].status = .idle
            }
        }
    }

    /// 全新构建（删除 node_modules 后重装再打包）
    func cleanBuildProject(_ project: Project) async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].status = .installing

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.cleanBuild(
            project: project,
            cloudDriveURL: cloudDriveURL.isEmpty ? nil : cloudDriveURL,
            onStatusChange: { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if let idx = self.projects.firstIndex(where: { $0.id == project.id }) {
                        self.projects[idx].status = status
                    }
                }
            }
        )
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream {
                self?.logStore.append(chunk, for: path)
            }
            guard let self else { return }
            if let idx = self.projects.firstIndex(where: { $0.id == project.id }) {
                self.projects[idx].status = .idle
            }
        }
    }

    /// 重装依赖
    func reinstallProject(_ project: Project) async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].status = .installing

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.reinstall(project: project)
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream {
                self?.logStore.append(chunk, for: path)
            }
            guard let self else { return }
            await self.processManager.stop(projectPath: project.path)
            if let idx = self.projects.firstIndex(where: { $0.id == project.id }) {
                self.projects[idx].status = .idle
            }
        }
    }

    /// 切换底部日志面板：点击同一项目关闭面板，点击不同项目切换显示
    func toggleLogPanel(for project: Project) {
        if logViewingProjectID == project.id {
            logViewingProjectID = nil
        } else {
            logViewingProjectID = project.id
        }
    }

    // MARK: - 快捷操作

    /// 在 Finder 中打开项目目录
    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path.path)
    }

    /// 在指定编辑器中打开项目（直接使用 .app 路径，与 Finder"打开方式"行为一致）
    func openInEditor(_ project: Project, editor: EditorInfo) {
        NSWorkspace.shared.open(
            [project.path],
            withApplicationAt: editor.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// 检测系统已安装的编辑器，获取真实应用名称和路径
    func detectEditors() async {
        var found: [EditorInfo] = []
        for bundleID in Self.editorBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) {
                found.append(info)
            }
        }
        detectedEditors = found

        // 检测 HBuilderX
        hbuilderxInfo = nil
        for bundleID in Self.hbuilderxBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) {
                hbuilderxInfo = info
                break
            }
        }

        // 检测微信开发者工具
        wechatDevToolsInfo = nil
        for bundleID in Self.wechatDevToolsBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) {
                wechatDevToolsInfo = info
                break
            }
        }
    }

    /// 通过 Spotlight 查找应用，返回实际显示名称和路径
    private func findEditorInfo(bundleID: String) async -> EditorInfo? {
        await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            proc.arguments = ["kMDItemCFBundleIdentifier == '\(bundleID)'"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: "\n").first
                    if let path, !path.isEmpty {
                        let url = URL(fileURLWithPath: path)
                        if FileManager.default.fileExists(atPath: path) {
                            // 使用系统本地化显示名称（与 Finder 中显示一致）
                            let displayName = FileManager.default.displayName(atPath: path)
                            return EditorInfo(
                                id: bundleID,
                                displayName: displayName,
                                appURL: url
                            )
                        }
                    }
                }
            } catch {}
            return nil
        }.value
    }

    /// 在终端中打开项目目录
    func openInTerminal(_ project: Project) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(project.path.path)'"
        end tell
        """
        Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
        }
    }

    /// 将项目移到废纸篓
    func trashProject(_ project: Project) async {
        // 先停止正在运行的进程
        if project.status != .idle {
            await stopProject(project)
        }

        // 从置顶列表中移除
        pinnedProjectPaths.remove(project.path.path)
        if let data = try? JSONEncoder().encode(pinnedProjectPaths) {
            UserDefaults.standard.set(data, forKey: savedPinnedKey)
        }

        // 移到废纸篓
        do {
            try FileManager.default.trashItem(at: project.path, resultingItemURL: nil)
            // 从项目列表中移除
            projects.removeAll { $0.id == project.id }
        } catch {
            print("移到废纸篓失败: \(error)")
        }
    }

    /// 批量删除所有项目的构建产物（构建输出目录和压缩包）
    func deleteAllBuilds() async {
        isBatchOperating = true
        let projectInfos = projects.map { (path: $0.path, outDir: $0.buildOutDir) }

        let deleted = await Task.detached {
            let fm = FileManager.default
            var count = 0
            for (path, outDir) in projectInfos {
                let dist = path.appendingPathComponent(outDir)
                let zip = path.appendingPathComponent("\(outDir).zip")
                if fm.fileExists(atPath: dist.path) {
                    try? fm.removeItem(at: dist)
                    count += 1
                }
                if fm.fileExists(atPath: zip.path) {
                    try? fm.removeItem(at: zip)
                    count += 1
                }
            }
            return count
        }.value

        isBatchOperating = false
        toastMessage = "已删除 \(deleted) 个构建产物"
    }

    /// 批量删除所有项目的依赖（node_modules）
    func deleteAllDependencies() async {
        isBatchOperating = true
        let projectPaths = projects.map(\.path)

        let deleted = await Task.detached {
            let fm = FileManager.default
            var count = 0
            for path in projectPaths {
                let nm = path.appendingPathComponent("node_modules")
                if fm.fileExists(atPath: nm.path) {
                    try? fm.removeItem(at: nm)
                    count += 1
                }
            }
            return count
        }.value

        isBatchOperating = false
        toastMessage = "已删除 \(deleted) 个依赖目录"
    }

    // MARK: - 应用退出清理

    /// 停止所有进程（应用退出时调用）
    func cleanup() async {
        await processManager.stopAll()
    }
}
