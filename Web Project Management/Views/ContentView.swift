import SwiftUI

// MARK: - 主内容视图
// 根据应用状态显示引导界面或项目网格，底部附带统一终端面板

struct ContentView: View {
    @Bindable var appState: AppState

    @State private var showSettings = false
    @State private var searchText = ""
    @State private var frameworkFilter: FrameworkType?
    @State private var statusFilter: ProjectStatus?
    @State private var showDeleteBuildsConfirm = false
    @State private var showDeleteDepsConfirm = false
    @FocusState private var isSearchFocused: Bool

    /// 是否有活跃的筛选条件
    private var hasActiveFilters: Bool {
        !searchText.isEmpty || frameworkFilter != nil || statusFilter != nil
    }

    /// 按搜索关键词和筛选条件过滤后的项目列表
    private var filteredProjects: [Project] {
        appState.sortedProjects.filter { project in
            // 名称搜索
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let nameMatch = project.name.lowercased().contains(query)
                let branchMatch = project.gitBranch?.lowercased().contains(query) ?? false
                let pathMatch = project.path.lastPathComponent.lowercased().contains(query)
                if !nameMatch && !branchMatch && !pathMatch { return false }
            }
            // 框架筛选
            if let fw = frameworkFilter, project.frameworkType != fw { return false }
            // 状态筛选
            if let st = statusFilter, project.status != st { return false }
            return true
        }
    }

    /// 当前底部面板正在查看的项目（如果有）
    private var logViewingProject: Project? {
        guard let id = appState.logViewingProjectID else { return nil }
        return appState.projects.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            AnimatedBackgroundView()

            // 隐藏按钮：保留 Cmd+F 聚焦搜索框的快捷键
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .frame(width: 0, height: 0)

            if appState.isFirstLaunch && appState.projects.isEmpty {
                EmptyStateView(
                    onSelectDirectory: { appState.selectDirectory() },
                    onDropDirectory: { url in appState.setRootDirectory(url) }
                )
            } else {
                VStack(spacing: 0) {
                    projectGridContent
                    // 底部统一终端面板
                    if let project = logViewingProject {
                        BottomLogPanel(
                            project: project,
                            logStore: appState.logStore,
                            appState: appState
                        )
                        .transition(.move(edge: .bottom))
                    }
                }
            }

            // 扫描中覆盖层（全屏居中）
            if appState.isScanning {
                ScanningOverlay()
            }
        }
        .toolbar {
            toolbarContent
        }
        .navigationTitle("")
        .sheet(isPresented: $showSettings) {
            SettingsSheet(appState: appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showAddProject },
            set: { appState.showAddProject = $0 }
        )) {
            AddProjectSheet(appState: appState)
        }
        .confirmationDialog(
            "确认删除所有项目的构建产物（dist 和 dist.zip）？",
            isPresented: $showDeleteBuildsConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                appState.deleteAllBuilds()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "确认删除所有项目的依赖（node_modules）？",
            isPresented: $showDeleteDepsConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                appState.deleteAllDependencies()
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 项目网格内容

    private var projectGridContent: some View {
        VStack(spacing: 0) {
            // 顶部信息栏
            if let root = appState.rootDirectory {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.45))

                    Text(root.path)
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if hasActiveFilters {
                        Text("\(filteredProjects.count) / \(appState.projects.count) 个项目")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.4, green: 0.5, blue: 0.7))
                    } else {
                        Text("\(appState.projects.count) 个项目")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.55))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color(red: 0.93, green: 0.93, blue: 0.94))

                // 搜索与筛选栏
                SearchFilterBar(
                    searchText: $searchText,
                    frameworkFilter: $frameworkFilter,
                    statusFilter: $statusFilter,
                    hasActiveFilters: hasActiveFilters,
                    isSearchFocused: $isSearchFocused
                )
            }

            // 自适应网格布局
            ScrollView {
                if filteredProjects.isEmpty && hasActiveFilters {
                    // 筛选无结果
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title)
                            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.65))
                        Text("没有匹配的项目")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.55))
                        Button("清除筛选") {
                            searchText = ""
                            frameworkFilter = nil
                            statusFilter = nil
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(filteredProjects) { project in
                            ProjectCardView(
                                project: project,
                                appState: appState,
                                isPinned: appState.pinnedProjectPaths.contains(project.path.path)
                            )
                            .equatable()
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { appState.showAddProject = true }) {
                Label("添加", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState.rootDirectory == nil)
            .help("从 Git 克隆项目")

            Button(action: { Task { await appState.scanProjects() } }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isScanning || appState.rootDirectory == nil)
            .help("重新扫描项目目录")

            Button(action: { appState.selectDirectory() }) {
                Label("更换目录", systemImage: "folder.badge.gearshape")
            }
            .help("选择新的项目集根目录")

            Button(action: { showSettings = true }) {
                Label("设置", systemImage: "gear")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("应用设置")

            Menu {
                Button(role: .destructive) {
                    showDeleteBuildsConfirm = true
                } label: {
                    Label("删除所有构建", systemImage: "trash")
                }

                Button(role: .destructive) {
                    showDeleteDepsConfirm = true
                } label: {
                    Label("删除所有依赖", systemImage: "trash")
                }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("批量操作")
        }
    }
}

// MARK: - 扫描中覆盖层

private struct ScanningOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("正在扫描项目...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(Color(red: 0.96, green: 0.96, blue: 0.97).opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - 设置弹窗

private struct SettingsSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draftURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("云盘网站")
                    .font(.headline)

                TextField("https://example.com", text: $draftURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)

                Text("构建并压缩完成后，自动在浏览器中打开此地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    appState.saveCloudDriveURL(draftURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 220)
        .onAppear {
            draftURL = appState.cloudDriveURL
        }
    }
}

// MARK: - 添加项目弹窗

private struct AddProjectSheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var gitURL: String = ""
    @State private var isCloning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("添加项目")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("项目 Git 地址")
                    .font(.headline)

                TextField("https://github.com/user/repo.git", text: $gitURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 360)
                    .disabled(isCloning)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCloning)

                Button("确定") {
                    isCloning = true
                    errorMessage = nil
                    Task {
                        let error = await appState.cloneProject(gitURL: gitURL)
                        isCloning = false
                        if let error {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(gitURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCloning)
            }
        }
        .padding(24)
        .frame(width: 440, height: 220)
    }
}

// MARK: - 搜索与筛选栏

private struct SearchFilterBar: View {
    @Binding var searchText: String
    @Binding var frameworkFilter: FrameworkType?
    @Binding var statusFilter: ProjectStatus?
    let hasActiveFilters: Bool
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.6))

                TextField("搜索项目名称、分支...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isSearchFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.90, green: 0.90, blue: 0.92))
            )
            .frame(maxWidth: 280)

            Divider()
                .frame(height: 20)
                .opacity(0.4)

            // 框架筛选
            ForEach(FrameworkType.allCases, id: \.self) { fw in
                FilterChip(
                    label: fw.rawValue,
                    isActive: frameworkFilter == fw,
                    activeColor: fw.accentColor
                ) {
                    frameworkFilter = frameworkFilter == fw ? nil : fw
                }
            }

            Divider()
                .frame(height: 20)
                .opacity(0.4)

            // 状态筛选
            ForEach([ProjectStatus.running, .installing, .building, .compressing], id: \.self) { status in
                FilterChip(
                    label: status.description,
                    isActive: statusFilter == status,
                    activeColor: status.iconColor,
                    icon: status.iconName
                ) {
                    statusFilter = statusFilter == status ? nil : status
                }
            }

            Spacer()

            // 清除筛选
            if hasActiveFilters {
                Button {
                    searchText = ""
                    frameworkFilter = nil
                    statusFilter = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                        Text("清除")
                            .font(.caption2)
                    }
                    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(red: 0.945, green: 0.945, blue: 0.955))
    }
}

// MARK: - 筛选标签

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    var activeColor: Color = .accentColor
    var icon: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(isActive ? activeColor : Color(red: 0.45, green: 0.45, blue: 0.5))
            .background(
                Capsule()
                    .fill(
                        isActive ? activeColor.opacity(0.12)
                        : (isHovering ? Color.gray.opacity(0.08) : Color.clear)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(isActive ? activeColor.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}
