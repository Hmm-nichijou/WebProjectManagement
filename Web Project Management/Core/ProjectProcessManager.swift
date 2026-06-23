import Foundation
import AppKit

// MARK: - 进程管理器 (Actor)
// 使用 Swift 6 actor 确保多任务并发时绝对的数据竞争安全

actor ProjectProcessManager {

    // MARK: - 进程会话

    /// 单个项目的进程会话，仅在 actor 内部使用
    private final class Session {
        var process: Process?
        var log: String = ""
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

    func build(project: Project, cloudDriveURL: String? = nil, onStatusChange: (@Sendable (ProjectStatus) -> Void)? = nil) -> AsyncStream<String> {
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

        // 先清理旧的 dist 目录和 dist.zip
        let distURL = project.path.appendingPathComponent("dist")
        let distZipURL = project.path.appendingPathComponent("dist.zip")
        clearDirectory(distURL)
        try? FileManager.default.removeItem(at: distZipURL)
        session.log += "[清理] 已删除旧 dist 目录和 dist.zip\n"

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

        // 构建完成后自动压缩 dist 目录
        let projectPath = project.path
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            Task {
                await self.handleTermination(path: path, exitCode: proc.terminationStatus)

                // 构建成功则压缩 dist 目录
                if proc.terminationStatus == 0 {
                    let dist = projectPath.appendingPathComponent("dist")
                    if FileManager.default.fileExists(atPath: dist.path) {
                        onStatusChange?(.compressing)
                        await self.zipDist(projectPath: projectPath, path: path)

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

    func cleanBuild(project: Project, cloudDriveURL: String? = nil, onStatusChange: (@Sendable (ProjectStatus) -> Void)? = nil) -> AsyncStream<String> {
        let path = project.path.path
        let session = Session()
        let packageManager = project.packageManager ?? .npm

        // 清理 node_modules、dist、dist.zip
        clearDirectory(project.path.appendingPathComponent("node_modules"))
        clearDirectory(project.path.appendingPathComponent("dist"))
        try? FileManager.default.removeItem(at: project.path.appendingPathComponent("dist.zip"))
        session.log += "[清理] 已删除 node_modules、dist、dist.zip\n"

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

                // 清理 dist 准备构建
                await self.clearDirectory(projectPath.appendingPathComponent("dist"))
                try? FileManager.default.removeItem(at: projectPath.appendingPathComponent("dist.zip"))

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

                buildProcess.terminationHandler = { [weak self] bProc in
                    guard let self else { return }
                    Task {
                        await self.handleTermination(path: path, exitCode: bProc.terminationStatus)

                        if bProc.terminationStatus == 0 {
                            let dist = projectPath.appendingPathComponent("dist")
                            if FileManager.default.fileExists(atPath: dist.path) {
                                onStatusChange?(.compressing)
                                await self.zipDist(projectPath: projectPath, path: path)

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
        session.log += "[清理] 已删除旧 node_modules\n"

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

    /// 构建完成后压缩 dist 目录为 dist.zip
    private func zipDist(projectPath: URL, path: String) async {
        guard let session = sessions[path] else { return }
        appendLog("[压缩] 正在打包 dist.zip...\n", to: session)

        let zipProcess = Process()
        zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProcess.arguments = ["-r", "dist.zip", "dist"]
        zipProcess.currentDirectoryURL = projectPath

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        zipProcess.standardOutput = outputPipe
        zipProcess.standardError = errorPipe

        setupPipeReading(pipe: outputPipe, path: path, session: session)
        setupPipeReading(pipe: errorPipe, path: path, session: session)

        do {
            try zipProcess.run()
            // 等待 zip 进程完成
            zipProcess.waitUntilExit()
            if zipProcess.terminationStatus == 0 {
                appendLog("[压缩] dist.zip 打包完成 ✓\n", to: session)
            } else {
                appendLog("[压缩] dist.zip 打包失败 (code: \(zipProcess.terminationStatus))\n", to: session)
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
        session.log += text
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
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin",
            "\(NSHomeDirectory())/.volta/bin",
            "\(NSHomeDirectory())/.fnm/aliases/default/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        return env
    }
}
