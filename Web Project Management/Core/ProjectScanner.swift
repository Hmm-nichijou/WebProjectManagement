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
        var hasNodeModules = false

        // 检测 node_modules 是否存在
        let nodeModulesPath = url.appendingPathComponent("node_modules")
        hasNodeModules = fm.fileExists(atPath: nodeModulesPath.path)

        // 检测包管理器类型（通过锁文件）
        packageManager = detectPackageManager(at: url)

        if fm.fileExists(atPath: packageJSONPath.path) {
            // 存在 package.json —— 解析依赖和 scripts
            let data = try Data(contentsOf: packageJSONPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                frameworkType = detectFramework(from: json)
                if let scriptsDict = json["scripts"] as? [String: String] {
                    scripts = scriptsDict
                }
            }
        } else {
            // 无 package.json，检查是否为 HTML 静态项目
            let indexPath = url.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexPath.path) {
                frameworkType = .htmlStatic
            } else {
                // 无法识别的项目类型，跳过
                throw NSError(domain: "ProjectScanner", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "无法识别项目类型: \(name)"
                ])
            }
        }

        // 检测 git 当前分支
        let gitBranch = await detectGitBranch(at: url)

        return Project(
            name: name,
            path: url,
            frameworkType: frameworkType,
            packageManager: packageManager,
            scripts: scripts,
            hasNodeModules: hasNodeModules,
            gitBranch: gitBranch
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

    // MARK: - 智能框架识别

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
