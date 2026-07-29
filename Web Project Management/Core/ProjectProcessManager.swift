import Foundation
import AppKit

// MARK: - 进程管理器 (Actor)
// 使用 Swift 6 actor 确保多任务并发时绝对的数据竞争安全

actor ProjectProcessManager {

    // MARK: - 进程会话

    /// 单个项目的进程会话，仅在 actor 内部使用
    private final class Session {
        var process: Process?
        var logContinuation: AsyncStream<String>.Continuation?

        deinit {
            logContinuation?.finish()
        }
    }

    /// 活跃会话字典，key 为项目路径字符串
    private var sessions: [String: Session] = [:]

    // MARK: - 启动开发服务器

    func start(project: Project, script: String) -> AsyncStream<String> {
        let path = project.path.path

        // 如果已在运行，先停止
        if let session = sessions[path], let process = session.process, process.isRunning {
            terminateProcess(process)
        }

        let session = Session()
        let packageManager = project.packageManager ?? .npm

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [packageManager.executable, "run", script]
        process.currentDirectoryURL = project.path
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // 创建日志异步流
        let stream = AsyncStream<String> { continuation in
            session.logContinuation = continuation
            continuation.onTermination = { @Sendable _ in }
        }

        // 设置 stdout 实时读取
        setupPipeReading(
            pipe: outputPipe,
            path: path,
            session: session
        )

        // 设置 stderr 实时读取
        setupPipeReading(
            pipe: errorPipe,
            path: path,
            session: session
        )

        // 进程终止回调
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(path: path, exitCode: proc.terminationStatus)
                await self.finishContinuation(for: path)
            }
        }

        session.process = process
        sessions[path] = session

        do {
            try process.run()
            appendLog("[启动] \(packageManager.executable) run \(script)\n", to: session)
        } catch {
            appendLog("[错误] 启动失败: \(error.localizedDescription)\n", to: session)
        }

        return stream
    }

    // MARK: - 执行构建

    func build(project: Project, cloudDriveURL: String? = nil, packageFormat: PackageFormat = .zip, onStatusChange: (@Sendable (ProjectStatus) -> Void)? = nil) -> AsyncStream<String> {
        let path = project.path.path
        let session = Session()
        let packageManager = project.packageManager ?? .npm

        // 确定构建脚本：优先 border，其次 build
        let buildScript: String
        if project.scripts["border"] != nil {
            buildScript = "border"
        } else {
            buildScript = "build"
        }

        // 先清理旧的构建输出目录和压缩包
        let outDir = project.buildOutDir
        let distURL = project.path.appendingPathComponent(outDir)
        let archiveURL = project.path.appendingPathComponent(packageFormat.archiveName(for: outDir))
        clearDirectory(distURL)
        try? FileManager.default.removeItem(at: archiveURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [packageManager.executable, "run", buildScript]
        process.currentDirectoryURL = project.path
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stream = AsyncStream<String> { continuation in
            session.logContinuation = continuation
        }

        setupPipeReading(pipe: outputPipe, path: path, session: session)
        setupPipeReading(pipe: errorPipe, path: path, session: session)

        // 构建完成后自动压缩构建输出目录
        let projectPath = project.path
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(path: path, exitCode: proc.terminationStatus)

                // 构建成功则压缩构建输出目录
                if proc.terminationStatus == 0 {
                    let dist = projectPath.appendingPathComponent(outDir)
                    if FileManager.default.fileExists(atPath: dist.path) {
                        onStatusChange?(.compressing)
                        await self.archiveDist(projectPath: projectPath, path: path, outDir: outDir, format: packageFormat)

                        // 压缩完成后在浏览器中打开云盘网站
                        if let urlStr = cloudDriveURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                            NSWorkspace.shared.open(url)
                            await self.appendLogToSession("[完成] 已在浏览器中打开云盘网站\n", path: path)
                        }
                    }
                }

                // 所有后置工作完成后再关闭日志流
                await self.finishContinuation(for: path)
            }
        }

        session.process = process
        sessions[path] = session

        do {
            try process.run()
            appendLog("[构建] \(packageManager.executable) run \(buildScript)\n", to: session)
        } catch {
            appendLog("[错误] 构建失败: \(error.localizedDescription)\n", to: session)
        }

        return stream
    }

    // MARK: - 全新构建（重装 + 打包）

    func cleanBuild(project: Project, cloudDriveURL: String? = nil, packageFormat: PackageFormat = .zip, onStatusChange: (@Sendable (ProjectStatus) -> Void)? = nil) -> AsyncStream<String> {
        let path = project.path.path
        let session = Session()
        let packageManager = project.packageManager ?? .npm

        // 清理 node_modules、构建输出目录、压缩包
        let outDir = project.buildOutDir
        clearDirectory(project.path.appendingPathComponent("node_modules"))
        clearDirectory(project.path.appendingPathComponent(outDir))
        try? FileManager.default.removeItem(at: project.path.appendingPathComponent(packageFormat.archiveName(for: outDir)))

        // 预计算环境变量（安装和构建共用）
        let env = buildEnvironment()

        // === 第一步：安装依赖 ===
        let installProcess = Process()
        installProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        installProcess.arguments = [packageManager.executable, packageManager.installCommand]
        installProcess.currentDirectoryURL = project.path
        installProcess.environment = env

        let installOut = Pipe()
        let installErr = Pipe()
        installProcess.standardOutput = installOut
        installProcess.standardError = installErr

        let stream = AsyncStream<String> { continuation in
            session.logContinuation = continuation
        }

        setupPipeReading(pipe: installOut, path: path, session: session)
        setupPipeReading(pipe: installErr, path: path, session: session)

        let projectPath = project.path
        installProcess.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(path: path, exitCode: proc.terminationStatus)

                if proc.terminationStatus != 0 {
                    await self.appendLogToSession("[错误] 依赖安装失败，终止构建\n", path: path)
                    await self.finishContinuation(for: path)
                    return
                }

                // === 第二步：执行构建（复用同一日志流） ===
                await self.appendLogToSession("\n[构建] 开始执行构建...\n", path: path)
                onStatusChange?(.building)

                let buildScript: String = project.scripts["border"] != nil ? "border" : "build"

                // 清理构建输出目录准备构建
                await self.clearDirectory(projectPath.appendingPathComponent(outDir))
                try? FileManager.default.removeItem(at: projectPath.appendingPathComponent(packageFormat.archiveName(for: outDir)))

                let buildProcess = Process()
                buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                buildProcess.arguments = [packageManager.executable, "run", buildScript]
                buildProcess.currentDirectoryURL = projectPath
                buildProcess.environment = env

                let buildOut = Pipe()
                let buildErr = Pipe()
                buildProcess.standardOutput = buildOut
                buildProcess.standardError = buildErr

                // 管道读取仍指向同一 session 的 continuation，无需创建新日志流
                await self.setupPipeReadingForSession(pipe: buildOut, path: path)
                await self.setupPipeReadingForSession(pipe: buildErr, path: path)

                buildProcess.terminationHandler = { bProc in
                    Task {
                        await self.handleTermination(path: path, exitCode: bProc.terminationStatus)

                        if bProc.terminationStatus == 0 {
                            let dist = projectPath.appendingPathComponent(outDir)
                            if FileManager.default.fileExists(atPath: dist.path) {
                                onStatusChange?(.compressing)
                                await self.archiveDist(projectPath: projectPath, path: path, outDir: outDir, format: packageFormat)

                                if let urlStr = cloudDriveURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                                    NSWorkspace.shared.open(url)
                                    await self.appendLogToSession("[完成] 已在浏览器中打开云盘网站\n", path: path)
                                }
                            }
                        }

                        await self.finishContinuation(for: path)
                        await self.stop(projectPath: projectPath)
                    }
                }

                await self.setSessionProcess(buildProcess, for: path)
                do {
                    try buildProcess.run()
                    await self.appendLogToSession("[构建] \(packageManager.executable) run \(buildScript)\n", path: path)
                } catch {
                    await self.appendLogToSession("[错误] 构建失败: \(error.localizedDescription)\n", path: path)
                    await self.finishContinuation(for: path)
                }
            }
        }

        session.process = installProcess
        sessions[path] = session

        do {
            try installProcess.run()
            appendLog("[安装] \(packageManager.executable) \(packageManager.installCommand)\n", to: session)
        } catch {
            appendLog("[错误] 安装失败: \(error.localizedDescription)\n", to: session)
        }

        return stream
    }

    // MARK: - 重装依赖

    func reinstall(project: Project) -> AsyncStream<String> {
        let path = project.path.path
        let session = Session()
        let packageManager = project.packageManager ?? .npm

        // 先删除旧的 node_modules
        let nodeModulesURL = project.path.appendingPathComponent("node_modules")
        clearDirectory(nodeModulesURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [packageManager.executable, packageManager.installCommand]
        process.currentDirectoryURL = project.path
        process.environment = buildEnvironment()

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stream = AsyncStream<String> { continuation in
            session.logContinuation = continuation
        }

        setupPipeReading(pipe: outputPipe, path: path, session: session)
        setupPipeReading(pipe: errorPipe, path: path, session: session)

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(path: path, exitCode: proc.terminationStatus)
                await self.finishContinuation(for: path)
            }
        }

        session.process = process
        sessions[path] = session

        do {
            try process.run()
            appendLog("[重装] \(packageManager.executable) \(packageManager.installCommand)\n", to: session)
        } catch {
            appendLog("[错误] 重装失败: \(error.localizedDescription)\n", to: session)
        }

        return stream
    }

    // MARK: - 停止进程

    func stop(projectPath: URL) {
        let path = projectPath.path
        guard let session = sessions[path] else { return }

        if let process = session.process, process.isRunning {
            terminateProcess(process)
        }

        session.logContinuation?.finish()
        sessions.removeValue(forKey: path)
    }

    // MARK: - 停止所有进程（应用退出时调用）

    func stopAll() {
        for (_, session) in sessions {
            if let process = session.process, process.isRunning {
                terminateProcess(process)
            }
            session.logContinuation?.finish()
        }
        sessions.removeAll()
    }

    // MARK: - 私有方法

    /// 递归删除指定目录（如果存在）
    private func clearDirectory(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
    }

    /// 构建完成后压缩构建输出目录
    private func archiveDist(projectPath: URL, path: String, outDir: String, format: PackageFormat) async {
        guard let session = sessions[path] else { return }
        let archiveName = format.archiveName(for: outDir)
        appendLog("[压缩] 正在打包 \(archiveName)...\n", to: session)

        let archiveProcess = Process()
        archiveProcess.currentDirectoryURL = projectPath

        switch format {
        case .zip:
            archiveProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            archiveProcess.arguments = ["-r", archiveName, outDir]
        case .tar:
            // tar -czvf archive.tar.gz ./dist
            archiveProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            archiveProcess.arguments = ["-czvf", archiveName, "./\(outDir)"]
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        archiveProcess.standardOutput = outputPipe
        archiveProcess.standardError = errorPipe

        setupPipeReading(pipe: outputPipe, path: path, session: session)
        setupPipeReading(pipe: errorPipe, path: path, session: session)

        do {
            try archiveProcess.run()
            archiveProcess.waitUntilExit()
            if archiveProcess.terminationStatus == 0 {
                appendLog("[压缩] \(archiveName) 打包完成 ✓\n", to: session)
            } else {
                appendLog("[压缩] \(archiveName) 打包失败 (code: \(archiveProcess.terminationStatus))\n", to: session)
            }
        } catch {
            appendLog("[错误] 压缩失败: \(error.localizedDescription)\n", to: session)
        }
    }

    /// 安全终止进程，防止僵尸进程
    private func terminateProcess(_ process: Process) {
        guard process.isRunning else { return }
        // 先尝试发送 SIGINT（优雅退出）
        kill(process.processIdentifier, SIGINT)
        // 给进程短暂时间退出
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// 处理进程终止事件（仅记录退出状态，不关闭日志流——由调用方控制关闭时机）
    private func handleTermination(path: String, exitCode: Int32) {
        guard let session = sessions[path] else { return }
        let statusText = exitCode == 0 ? "正常退出" : "异常退出 (code: \(exitCode))"
        appendLog("\n[进程] \(statusText)\n", to: session)
    }

    /// 关闭日志流（由调用方在所有日志输出完成后调用）
    private func finishContinuation(for path: String) {
        sessions[path]?.logContinuation?.finish()
    }

    /// 设置管道实时读取
    private func setupPipeReading(pipe: Pipe, path: String, session: Session) {
        let handle = pipe.fileHandleForReading

        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8),
                  let self else { return }

            Task { await self.processOutput(chunk: chunk, path: path) }
        }
    }

    /// 按路径查找 session 并设置管道读取（避免 non-Sendable 跨 actor 边界）
    private func setupPipeReadingForSession(pipe: Pipe, path: String) {
        guard let session = sessions[path] else { return }
        setupPipeReading(pipe: pipe, path: path, session: session)
    }

    /// 按路径查找 session 并设置其进程
    private func setSessionProcess(_ process: Process, for path: String) {
        sessions[path]?.process = process
    }

    /// 处理管道输出
    private func processOutput(chunk: String, path: String) {
        guard let session = sessions[path] else { return }
        appendLog(chunk, to: session)
    }

    /// 向日志追加内容并推送给流订阅者
    private func appendLog(_ text: String, to session: Session) {
        session.logContinuation?.yield(text)
    }

    /// 按路径查找 session 并追加日志（避免 non-Sendable 跨 actor 边界）
    private func appendLogToSession(_ text: String, path: String) {
        guard let session = sessions[path] else { return }
        appendLog(text, to: session)
    }

    /// 构建包含常见 Node.js 路径的环境变量
    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var extraPaths: [String] = []

        // nvm 的 `~/.nvm/versions/node/*/bin` 是 glob 通配符，Process 不经过 shell 不会展开，
        // 需手动解析实际安装的版本目录（默认版本优先）
        extraPaths.append(contentsOf: resolveNvmPaths(home: home))

        extraPaths.append(contentsOf: [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/aliases/default/bin",
        ])

        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }

    /// 解析 nvm 安装的 node 版本 bin 路径
    /// nvm 默认版本通过 `~/.nvm/alias/default` 文件指向（可能是版本号或 lts/* 别名）
    private func resolveNvmPaths(home: String) -> [String] {
        let fm = FileManager.default
        let versionsDir = "\(home)/.nvm/versions/node"
        guard fm.fileExists(atPath: versionsDir),
              let versions = try? fm.contentsOfDirectory(atPath: versionsDir) else {
            return []
        }

        var paths: [String] = []

        // 优先加入默认版本
        if let defaultVersion = readNvmDefaultVersion(home: home) {
            let binPath = "\(versionsDir)/\(defaultVersion)/bin"
            if fm.fileExists(atPath: binPath) {
                paths.append(binPath)
            }
        }

        // 兜底：加入所有已安装版本（默认版本已在上方添加，这里去重）
        for version in versions {
            let binPath = "\(versionsDir)/\(version)/bin"
            if fm.fileExists(atPath: binPath) && !paths.contains(binPath) {
                paths.append(binPath)
            }
        }

        return paths
    }

    /// 读取 nvm 默认版本（解析 `~/.nvm/alias/default`，支持版本号和 lts/* 别名引用）
    private func readNvmDefaultVersion(home: String) -> String? {
        let aliasPath = "\(home)/.nvm/alias/default"
        guard let content = try? String(contentsOfFile: aliasPath, encoding: .utf8) else { return nil }
        let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // 处理别名引用（如 lts/hydrogen → 读取 ~/.nvm/alias/lts/hydrogen）
        if raw.contains("/") {
            let parts = raw.split(separator: "/")
            if parts.count == 2 {
                let refPath = "\(home)/.nvm/alias/\(parts[0])/\(parts[1])"
                if let refContent = try? String(contentsOfFile: refPath, encoding: .utf8) {
                    let refVersion = refContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalizeNvmVersion(refVersion)
                }
            }
            return nil
        }

        return normalizeNvmVersion(raw)
    }

    /// 规范化版本号（nvm 目录名为 v18.20.0 形式，alias 文件可能是 18.20.0 或 v18.20.0）
    private func normalizeNvmVersion(_ version: String) -> String {
        version.hasPrefix("v") ? version : "v\(version)"
    }
}
