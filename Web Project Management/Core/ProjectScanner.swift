import Foundation

// MARK: - 项目扫描器
// 扫描指定根目录下的 Web 前端项目，识别框架类型和包管理器

struct ProjectScanner: Sendable {

    /// 扫描根目录，返回所有识别到的 Web 项目
    /// - Parameter rootURL: 用户选择的项目集根目录
    /// - Returns: 扫描到的项目数组
    func scan(rootURL: URL) async throws -> [Project] {
        let fm = FileManager.default
        var projects: [Project] = []

        // 仅扫描第一层子目录
        let contents = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for itemURL in contents {
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            if let project = try? await scanDirectory(itemURL) {
                projects.append(project)
            }
        }

        return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 扫描单个目录

    private func scanDirectory(_ url: URL) async throws -> Project {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let packageJSONPath = url.appendingPathComponent("package.json")

        var frameworkType: FrameworkType = .unknown
        var scripts: [String: String] = [:]
        var packageManager: PackageManagerType? = nil
        let hasNodeModules = fm.fileExists(atPath: url.appendingPathComponent("node_modules").path)

        // 检测包管理器类型（通过锁文件）
        packageManager = detectPackageManager(at: url)

        // 解析 package.json（只读一次）
        var packageJSON: [String: Any]?
        if fm.fileExists(atPath: packageJSONPath.path) {
            if let data = try? Data(contentsOf: packageJSONPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                packageJSON = json
                if let scriptsDict = json["scripts"] as? [String: String] {
                    scripts = scriptsDict
                }
            }
        }

        // 优先基于特征文件检测（不依赖 package.json）
        if let uniAppType = detectUniAppType(at: url) {
            frameworkType = uniAppType
        } else if detectWeChatMiniProgram(at: url) {
            frameworkType = .wechatMiniProgram
        } else if let json = packageJSON {
            // 通过 package.json 依赖识别框架
            frameworkType = detectFramework(from: json)
        } else {
            // 无 package.json，检查是否为 HTML 静态项目
            let indexPath = url.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexPath.path) {
                frameworkType = .htmlStatic
            }
            // 无法识别的项目类型保持 .unknown
        }

        // 检测 git 当前分支和状态
        let gitBranch = await detectGitBranch(at: url)
        let gitStatus = await detectGitStatus(at: url)

        // 计算磁盘占用
        let diskUsage = await calculateDiskUsage(at: url)

        return Project(
            name: name,
            path: url,
            frameworkType: frameworkType,
            packageManager: packageManager,
            scripts: scripts,
            hasNodeModules: hasNodeModules,
            gitBranch: gitBranch,
            gitStatus: gitStatus,
            nodeModulesSize: diskUsage.nodeModules,
            distSize: diskUsage.dist,
            distZipSize: diskUsage.distZip
        )
    }

    // MARK: - 检测 Git 分支

    private func detectGitBranch(at url: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            return nil
        }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.path, "branch", "--show-current"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin"]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let branch = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (branch?.isEmpty == true) ? nil : branch
        } catch {
            return nil
        }
    }

    // MARK: - 检测包管理器

    private func detectPackageManager(at url: URL) -> PackageManagerType? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("pnpm-lock.yaml").path) {
            return .pnpm
        } else if fm.fileExists(atPath: url.appendingPathComponent("yarn.lock").path) {
            return .yarn
        } else if fm.fileExists(atPath: url.appendingPathComponent("package-lock.json").path) {
            return .npm
        }
        return nil
    }

    // MARK: - 检测 Git 状态

    private func detectGitStatus(at url: URL) async -> GitStatus? {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
            return nil
        }

        return await Task.detached {
            var modified = 0, added = 0, untracked = 0

            // 解析 porcelain 格式的工作区状态
            let statusProc = Process()
            let statusPipe = Pipe()
            statusProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusProc.arguments = ["-C", url.path, "status", "--porcelain"]
            statusProc.standardOutput = statusPipe
            statusProc.standardError = FileHandle.nullDevice
            statusProc.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin"]

            do {
                try statusProc.run()
                statusProc.waitUntilExit()
                if statusProc.terminationStatus == 0 {
                    let data = statusPipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        for line in output.split(separator: "\n") {
                            guard line.count >= 2 else { continue }
                            let xy = String(line.prefix(2))
                            if xy == "??" {
                                untracked += 1
                            } else {
                                let index = xy.first ?? " "
                                let workTree = xy.last ?? " "
                                if index == "A" || index == "M" { added += 1 }
                                if workTree == "M" || workTree == "D" { modified += 1 }
                            }
                        }
                    }
                }
            } catch {}

            // 检测与远程分支的 ahead/behind
            var ahead = 0, behind = 0
            let revProc = Process()
            let revPipe = Pipe()
            revProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            revProc.arguments = ["-C", url.path, "rev-list", "--left-right", "--count", "HEAD...@{upstream}"]
            revProc.standardOutput = revPipe
            revProc.standardError = FileHandle.nullDevice
            revProc.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin"]

            do {
                try revProc.run()
                revProc.waitUntilExit()
                if revProc.terminationStatus == 0 {
                    let data = revPipe.fileHandleForReading.readDataToEndOfFile()
                    if let output = String(data: data, encoding: .utf8) {
                        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                            .split(separator: "\t")
                        if parts.count == 2 {
                            ahead = Int(parts[0]) ?? 0
                            behind = Int(parts[1]) ?? 0
                        }
                    }
                }
            } catch {}

            return GitStatus(
                modified: modified,
                added: added,
                untracked: untracked,
                ahead: ahead,
                behind: behind
            )
        }.value
    }

    // MARK: - 计算磁盘占用

    private func calculateDiskUsage(at url: URL) async -> (nodeModules: Int64, dist: Int64, distZip: Int64) {
        let fm = FileManager.default
        var nodeModulesSize: Int64 = 0
        var distSize: Int64 = 0
        var distZipSize: Int64 = 0

        // node_modules 目录大小
        let nmPath = url.appendingPathComponent("node_modules")
        if fm.fileExists(atPath: nmPath.path) {
            nodeModulesSize = await Task.detached {
                Self.directorySize(at: nmPath)
            }.value
        }

        // dist 目录大小
        let distPath = url.appendingPathComponent("dist")
        if fm.fileExists(atPath: distPath.path) {
            distSize = await Task.detached {
                Self.directorySize(at: distPath)
            }.value
        }

        // dist.zip 文件大小
        let zipPath = url.appendingPathComponent("dist.zip")
        if fm.fileExists(atPath: zipPath.path) {
            if let attrs = try? fm.attributesOfItem(atPath: zipPath.path),
               let size = attrs[.size] as? Int64 {
                distZipSize = size
            }
        }

        return (nodeModulesSize, distSize, distZipSize)
    }

    /// 递归计算目录大小
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else { continue }
            totalSize += Int64(fileSize)
        }
        return totalSize
    }

    // MARK: - 检测 uni-app / uni-app x 项目（基于特征文件）

    private func detectUniAppType(at url: URL) -> FrameworkType? {
        let fm = FileManager.default

        // 查找 manifest.json 和 pages.json 的位置（可能在根目录或 src 子目录）
        let searchDirs = [url, url.appendingPathComponent("src")]
        var manifestPath: URL?
        var pagesPath: URL?

        for dir in searchDirs {
            let m = dir.appendingPathComponent("manifest.json")
            let p = dir.appendingPathComponent("pages.json")
            if fm.fileExists(atPath: m.path) { manifestPath = m }
            if fm.fileExists(atPath: p.path) { pagesPath = p }
        }

        // 必须同时存在 manifest.json 和 pages.json 才认定为 uni-app 系列项目
        guard let manifest = manifestPath, pagesPath != nil else {
            return nil
        }

        // 检测 uni-app x：manifest.json 中包含 "uni-app-x" 节点
        if let data = try? Data(contentsOf: manifest),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["uni-app-x"] != nil {
            return .uniappx
        }

        return .uniapp
    }

    // MARK: - 检测微信小程序项目

    private func detectWeChatMiniProgram(at url: URL) -> Bool {
        let fm = FileManager.default
        let pagesDir = url.appendingPathComponent("miniprogram").appendingPathComponent("pages")
        guard fm.fileExists(atPath: pagesDir.path) else { return false }

        // 递归查找 pages 目录下是否存在 .wxml 文件
        guard let enumerator = fm.enumerator(
            at: pagesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "wxml" {
                return true
            }
        }
        return false
    }

    // MARK: - 智能框架识别（基于 package.json 依赖）

    private func detectFramework(from json: [String: Any]) -> FrameworkType {
        let deps = json["dependencies"] as? [String: Any] ?? [:]
        let devDeps = json["devDependencies"] as? [String: Any] ?? [:]
        let allDeps = deps.merging(devDeps) { _, new in new }

        if allDeps["vue"] != nil {
            return .vue
        } else if allDeps["react"] != nil {
            return .react
        } else if allDeps["@angular/core"] != nil {
            return .angular
        }

        return .unknown
    }
}
