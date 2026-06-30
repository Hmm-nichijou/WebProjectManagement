import SwiftUI
import AppKit

// MARK: - 主题模式

enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
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

    // MARK: - 公开属性

    /// 用户选择的项目集根目录
    var rootDirectory: URL?

    /// 扫描到的项目列表
    var projects: [Project] = []

    /// 项目数据变更版本号（列表增减、置顶、状态变化时递增）
    /// ContentView 通过 .onChange 监听此值来重建过滤缓存
    var projectsRevision: Int = 0

    var isScanning = false
    var isBatchOperating = false
    var toastMessage: String?
    var isFirstLaunch = true
    var logViewingProjectID: UUID?
    var showAddProject = false
    var cloudDriveURL: String = ""

    /// 置顶的项目路径集合（使用绝对路径而非 UUID，确保重新扫描后置顶状态不丢失）
    var pinnedProjectPaths: Set<String> = []

    var detectedEditors: [EditorInfo] = []
    var hbuilderxInfo: EditorInfo?
    var wechatDevToolsInfo: EditorInfo?

    /// 主题模式（浅色/深色/跟随系统）
    var themeMode: ThemeMode = .system {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: savedThemeKey) }
    }

    // MARK: - 私有 / 常量

    let processManager = ProjectProcessManager()
    let logStore = LogStore()
    private var logStreams: [String: AsyncStream<String>] = [:]

    private static let editorBundleIDs = [
        "com.microsoft.VSCode",
        "com.jetbrains.WebStorm",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.sublimetext.4",
        "com.panic.Nova",
    ]
    private static let hbuilderxBundleIDs = ["io.dcloud.HBuilderX", "io.dcloud.HBuilderXAlpha"]
    private static let wechatDevToolsBundleIDs = ["com.tencent.webplusdevtools"]

    private let savedPathKey = "savedRootDirectory"
    private let savedCloudDriveKey = "savedCloudDriveURL"
    private let savedPinnedKey = "savedPinnedProjectIDs"
    private let savedThemeKey = "savedThemeMode"

    // MARK: - 初始化

    init() {
        loadSavedDirectory()
        cloudDriveURL = UserDefaults.standard.string(forKey: savedCloudDriveKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: savedPinnedKey),
           let pinned = try? JSONDecoder().decode(Set<String>.self, from: data) {
            pinnedProjectPaths = pinned
        }
        if let str = UserDefaults.standard.string(forKey: savedThemeKey),
           let mode = ThemeMode(rawValue: str) {
            themeMode = mode
        }
        Task { await detectEditors() }
    }

    func saveCloudDriveURL(_ url: String) {
        cloudDriveURL = url
        UserDefaults.standard.set(url, forKey: savedCloudDriveKey)
    }

    // MARK: - 目录管理

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

    func setRootDirectory(_ url: URL) {
        rootDirectory = url
        isFirstLaunch = false
        UserDefaults.standard.set(url.path, forKey: savedPathKey)
        Task { await scanProjects() }
    }

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

    // MARK: - 项目扫描（两阶段：快速展示 + 后台补充）

    func scanProjects() async {
        guard let root = rootDirectory else { return }
        isScanning = true

        let scanner = ProjectScanner()
        do {
            projects = try await scanner.scanQuick(rootURL: root)
            projectsRevision += 1
            isScanning = false

            await withTaskGroup(of: (UUID, Project).self) { group in
                for project in projects {
                    group.addTask { await (project.id, scanner.scanDeep(project: project)) }
                }
                for await (id, enriched) in group {
                    if let idx = projects.firstIndex(where: { $0.id == id }) {
                        var updated = enriched
                        updated.status = projects[idx].status
                        projects[idx] = updated
                        projectsRevision += 1
                    }
                }
            }
        } catch {
            isScanning = false
            print("扫描失败: \(error)")
        }
    }

    /// 刷新单个项目（先进入 loading，再深度扫描）
    func refreshProject(_ project: Project) async {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }

        projects[idx].isEnriched = false
        projectsRevision += 1

        let enriched = await ProjectScanner().scanDeep(project: project)
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            var updated = enriched
            updated.status = projects[idx].status
            projects[idx] = updated
            projectsRevision += 1
        }
    }

    // MARK: - 项目置顶

    func isPinned(_ project: Project) -> Bool {
        pinnedProjectPaths.contains(project.path.path)
    }

    func togglePin(_ project: Project) {
        let path = project.path.path
        if pinnedProjectPaths.contains(path) {
            pinnedProjectPaths.remove(path)
        } else {
            pinnedProjectPaths.insert(path)
        }
        savePinnedPaths()
        projectsRevision += 1
    }

    // MARK: - 项目状态更新（统一入口，确保 projectsRevision 同步递增）

    private func updateProjectStatus(_ project: Project, to status: ProjectStatus) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx].status = status
        projectsRevision += 1
    }

    // MARK: - Git 克隆

    @discardableResult
    func cloneProject(gitURL: String) async -> String? {
        guard let root = rootDirectory else { return "未设置项目根目录" }

        let name = gitURL.components(separatedBy: "/").last?
            .replacingOccurrences(of: ".git", with: "") ?? "project"
        let targetPath = root.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: targetPath.path) {
            return "目录 \(name) 已存在"
        }

        let path = targetPath.path
        logStore.clear(for: path)

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

            for pipe in [outputPipe, errorPipe] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    continuation.yield(text)
                }
            }

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(proc.terminationStatus == 0
                    ? "\n[完成] 克隆成功 ✓\n"
                    : "\n[错误] 克隆失败 (code: \(proc.terminationStatus))\n")
                continuation.finish()
            }

            do { try process.run() }
            catch { continuation.yield("\n[错误] \(error.localizedDescription)\n"); continuation.finish() }
        }

        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream { self?.logStore.append(chunk, for: path) }
        }

        for await _ in logStreams[path]! {}
        await scanProjects()

        if let newProject = projects.first(where: { $0.path.path == path }) {
            logViewingProjectID = newProject.id
        }
        return nil
    }

    // MARK: - 进程操作

    func startProject(_ project: Project, script: String = "dev") async {
        guard projects.contains(where: { $0.id == project.id }) else { return }

        let path = project.path.path
        logStore.clear(for: path)

        let stream = await processManager.start(project: project, script: script)
        logStreams[path] = stream

        updateProjectStatus(project, to: .running)
        logViewingProjectID = project.id

        Task { [weak self] in
            for await chunk in stream { self?.logStore.append(chunk, for: path) }
        }
    }

    func stopProject(_ project: Project) async {
        await processManager.stop(projectPath: project.path)
        logStreams.removeValue(forKey: project.path.path)
        updateProjectStatus(project, to: .idle)
        if logViewingProjectID == project.id {
            logViewingProjectID = nil
        }
    }

    func buildProject(_ project: Project) async {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        updateProjectStatus(project, to: .building)

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.build(
            project: project,
            cloudDriveURL: cloudDriveURL.isEmpty ? nil : cloudDriveURL,
            onStatusChange: { [weak self] status in
                Task { @MainActor in self?.updateProjectStatus(project, to: status) }
            }
        )
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream { self?.logStore.append(chunk, for: path) }
            guard let self else { return }
            await self.processManager.stop(projectPath: project.path)
            self.updateProjectStatus(project, to: .idle)
        }
    }

    func cleanBuildProject(_ project: Project) async {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        updateProjectStatus(project, to: .installing)

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.cleanBuild(
            project: project,
            cloudDriveURL: cloudDriveURL.isEmpty ? nil : cloudDriveURL,
            onStatusChange: { [weak self] status in
                Task { @MainActor in self?.updateProjectStatus(project, to: status) }
            }
        )
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream { self?.logStore.append(chunk, for: path) }
            guard let self else { return }
            self.updateProjectStatus(project, to: .idle)
        }
    }

    func reinstallProject(_ project: Project) async {
        guard projects.contains(where: { $0.id == project.id }) else { return }
        updateProjectStatus(project, to: .installing)

        let path = project.path.path
        logStore.clear(for: path)
        logViewingProjectID = project.id

        let stream = await processManager.reinstall(project: project)
        logStreams[path] = stream

        Task { [weak self] in
            for await chunk in stream { self?.logStore.append(chunk, for: path) }
            guard let self else { return }
            await self.processManager.stop(projectPath: project.path)
            self.updateProjectStatus(project, to: .idle)
        }
    }

    func toggleLogPanel(for project: Project) {
        logViewingProjectID = (logViewingProjectID == project.id) ? nil : project.id
    }

    // MARK: - 快捷操作

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path.path)
    }

    func openInEditor(_ project: Project, editor: EditorInfo) {
        NSWorkspace.shared.open(
            [project.path], withApplicationAt: editor.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

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

    func trashProject(_ project: Project) async {
        if project.status != .idle { await stopProject(project) }

        pinnedProjectPaths.remove(project.path.path)
        savePinnedPaths()

        do {
            try FileManager.default.trashItem(at: project.path, resultingItemURL: nil)
            projects.removeAll { $0.id == project.id }
            projectsRevision += 1
        } catch {
            print("移到废纸篓失败: \(error)")
        }
    }

    // MARK: - 批量操作

    func deleteAllBuilds() async {
        isBatchOperating = true
        let projectInfos = projects.map { (id: $0.id, path: $0.path, outDir: $0.buildOutDir) }

        let deleted = await Task.detached {
            let fm = FileManager.default
            var count = 0
            for (_, path, outDir) in projectInfos {
                let dist = path.appendingPathComponent(outDir)
                let zip = path.appendingPathComponent("\(outDir).zip")
                if fm.fileExists(atPath: dist.path) { try? fm.removeItem(at: dist); count += 1 }
                if fm.fileExists(atPath: zip.path) { try? fm.removeItem(at: zip); count += 1 }
            }
            return count
        }.value

        // 更新项目结构体中的磁盘占用数据
        for info in projectInfos {
            if let idx = projects.firstIndex(where: { $0.id == info.id }) {
                projects[idx].distSize = 0
                projects[idx].distZipSize = 0
            }
        }
        projectsRevision += 1

        isBatchOperating = false
        toastMessage = "已删除 \(deleted) 个构建产物"
    }

    func deleteAllDependencies() async {
        isBatchOperating = true
        let projectInfos = projects.map { (id: $0.id, path: $0.path) }

        let deleted = await Task.detached {
            let fm = FileManager.default
            var count = 0
            for (_, path) in projectInfos {
                let nm = path.appendingPathComponent("node_modules")
                if fm.fileExists(atPath: nm.path) { try? fm.removeItem(at: nm); count += 1 }
            }
            return count
        }.value

        // 更新项目结构体中的依赖数据
        for info in projectInfos {
            if let idx = projects.firstIndex(where: { $0.id == info.id }) {
                projects[idx].nodeModulesSize = 0
                projects[idx].hasNodeModules = false
            }
        }
        projectsRevision += 1

        isBatchOperating = false
        toastMessage = "已删除 \(deleted) 个依赖目录"
    }

    // MARK: - 编辑器检测

    func detectEditors() async {
        var found: [EditorInfo] = []
        for bundleID in Self.editorBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) { found.append(info) }
        }
        detectedEditors = found

        hbuilderxInfo = nil
        for bundleID in Self.hbuilderxBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) { hbuilderxInfo = info; break }
        }

        wechatDevToolsInfo = nil
        for bundleID in Self.wechatDevToolsBundleIDs {
            if let info = await findEditorInfo(bundleID: bundleID) { wechatDevToolsInfo = info; break }
        }
    }

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
                    if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                        return EditorInfo(
                            id: bundleID,
                            displayName: FileManager.default.displayName(atPath: path),
                            appURL: URL(fileURLWithPath: path)
                        )
                    }
                }
            } catch {}
            return nil
        }.value
    }

    // MARK: - 应用退出清理

    func cleanup() async { await processManager.stopAll() }

    // MARK: - 私有工具方法

    private func savePinnedPaths() {
        if let data = try? JSONEncoder().encode(pinnedProjectPaths) {
            UserDefaults.standard.set(data, forKey: savedPinnedKey)
        }
    }
}
