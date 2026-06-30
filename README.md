# Web Project Management

一款基于 Swift 6 + SwiftUI 构建的 macOS 原生桌面应用，专为前端开发者设计的项目管理工具。支持批量管理 Vue、React、Angular、uni-app、uni-app x、微信小程序及静态 HTML 项目，提供一键启动开发服务器、构建打包、依赖管理等常用操作，并以实时终端日志面板呈现执行过程。

## 技术栈

| 类别 | 技术 |
|------|------|
| 语言 | Swift 6（严格并发检查，`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`） |
| UI 框架 | SwiftUI（macOS 26.5+） |
| 状态管理 | `@Observable`（Observation 框架） |
| 并发模型 | Actor 隔离 + `AsyncStream` 日志流 |
| 进程管理 | Foundation `Process` + `Pipe`（App Sandbox 已关闭） |
| 应用检测 | Spotlight `mdfind` + `NSWorkspace` |
| 持久化 | `UserDefaults`（目录路径、置顶状态、云盘 URL、主题模式） |
| 构建系统 | Xcode 16+，`PBXFileSystemSynchronizedRootGroup`（源文件自动包含） |

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│               WebProjectManagementApp                   │
│                     (应用入口)                          │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌─────────────┐   ┌───────────────┐  ┌─────────────┐   │
│  │ ContentView │   │ProjectCardView│  │LogDrawerView│   │
│  │  (主界面)   │ ─▶│  (项目卡片)   │  │ (终端面板)  │   │
│  │  搜索/筛选  │   │  操作/状态    │  │  实时日志   │   │
│  └─────────────┘   └───────────────┘  └─────────────┘   │
│         │                │                  │           │
│         └────────────────┼──────────────────┘           │
│                          │                              │
│  ┌───────────────────────────────────────────────────┐  │
│  │              AppState (@Observable)               │  │
│  │     全局状态：项目列表、目录、置顶、编辑器        │  │
│  ├───────────────────────────────────────────────────┤  │
│  │  LogStore (@Observable)  ProjectProcessManager    │  │
│  │  独立日志存储            (Actor 进程管理)         │  │
│  │  按路径分代追踪          AsyncStream 日志流       │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────────┐                                   │
│  │ ProjectScanner   │                                   │
│  └──────────────────┘                                   │
│  扫描目录，识别框架与包管理器                           │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 核心设计原则

**两阶段扫描架构**：全局扫描采用快速展示 + 后台补充的两阶段策略。第一阶段（`scanQuick`）仅做文件检测，立即展示项目列表，卡片显示"加载中"状态；第二阶段（`scanDeep`）通过 `withTaskGroup` 并发执行 git 和磁盘操作，逐卡片更新。`Project.isEnriched` 标志区分"尚未扫描完成"和"确实无数据"，确保 UI 状态语义清晰。

**构建输出目录动态检测**：`ProjectScanner.detectBuildOutDir()` 解析 `vite.config.ts/js/mjs` 中的 `build.outDir` 配置，所有构建、压缩、清除操作均使用项目实际的输出目录名（默认 `dist`），支持自定义构建目录。

**日志与项目列表分离**：`LogStore` 作为独立的 `@Observable` 对象管理日志，通过按路径的"代数计数器"（generation counter）实现精准视图更新——日志追加仅触发对应项目的 `LogDrawerView` 重渲染，不会引起整个项目网格的重新计算。

**AsyncStream 单消费者模式**：`AsyncStream` 仅支持单个迭代器消费者。应用中由 `AppState` 内的后台 `Task` 统一消费日志流并写入 `LogStore`，UI 层通过 `Task.sleep(200ms)` 轮询 `LogStore` 获取最新日志，避免多消费者竞争。

**Actor 进程安全**：`ProjectProcessManager` 声明为 `actor`，确保多项目并发操作（启动、构建、安装）时的数据竞争安全。所有进程会话（`Session`）仅在 actor 内部访问。

**多阶段操作的 Continuation 生命周期管理**：`handleTermination` 仅记录退出状态，不关闭日志流。每个调用方（`build`、`cleanBuild`、`start`、`reinstall`）自行控制 `continuation.finish()` 的时机，确保构建后压缩、云盘打开等后续操作的日志不会丢失。`cleanBuild` 的两阶段流程（安装→构建）复用同一个 `AsyncStream` continuation。

**Equatable 卡片优化**：`ProjectCardView` 实现 `Equatable` 协议并在 `ForEach` 中使用 `.equatable()`，仅当项目数据或置顶状态变化时才重算卡片 body。编辑器信息（`hasEditors`、`hbuilderxInfo`、`wechatDevToolsInfo`）作为预计算参数从父视图传入，避免卡片 body 中直接读取 `@Observable` 属性导致 Equatable 优化失效。

**过滤缓存机制**：`filteredProjectsCache` 使用 `@State` 缓存排序 + 过滤结果，通过 `.onChange` 监听搜索文本、筛选条件和 `projectsRevision` 统一版本号重建，滚动时不再重复执行计算。`updateProjectStatus()` 方法统一处理状态赋值 + 版本号递增，确保所有数据变更路径一致。

## 功能特性

### 项目管理

- **目录扫描**：选择项目集根目录后自动扫描一级子目录，识别包含 `package.json`、`index.html` 或特征文件的项目。采用两阶段策略——快速展示列表后，后台并发补充 git 和磁盘数据
- **构建输出目录检测**：自动读取 `vite.config.ts/js/mjs` 中的 `build.outDir`，构建、压缩、清除构建物均使用项目实际输出目录名（默认 `dist`）
- **框架识别**：智能检测 Vue、React、Angular 项目（基于 `dependencies`/`devDependencies` 分析），uni-app / uni-app x 项目（基于 `manifest.json` + `pages.json` 特征文件），微信小程序项目（基于 `miniprogram/pages/*.wxml`），以及 HTML 静态项目。unknown 和微信小程序类型隐藏运行和构建按钮
- **包管理器检测**：通过锁文件（`package-lock.json`、`pnpm-lock.yaml`、`yarn.lock`）自动识别 npm/pnpm/yarn
- **node_modules 安装标签**：已安装 node_modules 的项目在卡片上显示绿色胶囊标签，未安装则不显示
- **Git 集成**：检测并展示当前分支名和工作区状态（修改/未跟踪/ahead/behind），工作区干净时不显示状态图标
- **磁盘占用统计**：信息栏汇总显示所有项目的 node_modules、dist、dist.zip 总占用
- **项目置顶**：置顶状态按绝对路径持久化到 UserDefaults，重新扫描或切换目录后不丢失
- **未知类型兼容**：无法识别的项目类型仍保留在列表中显示

### 搜索与筛选

- **实时搜索**：支持按项目名称、Git 分支名、路径关键词搜索（Cmd+F 聚焦）
- **Menu 下拉筛选**：框架类型和运行状态通过 Menu 下拉菜单分组筛选，选中状态实时体现在按钮上
- **结果统计**：筛选激活时显示匹配项目数 / 总项目数

### 进程操作

- **启动开发服务器**：执行 `npm/pnpm/yarn run dev`，实时输出日志
- **快速构建**：执行 `build`（或 `border`）脚本，构建成功后自动压缩输出目录为 `.zip`（目录名从 `vite.config` 动态读取）
- **全新构建**：两阶段流水线——删除 `node_modules` → 重装依赖 → 执行构建 → 压缩 dist
- **重装依赖**：删除 `node_modules` 后重新安装
- **取消构建**：构建/安装/压缩过程中可点击"取消构建"终止操作，启停按钮独立不受影响
- **停止进程**：先发送 `SIGINT` 优雅退出，超时后强制终止
- **云盘集成**：构建并压缩完成后自动在浏览器中打开配置的云盘网站

### 项目状态

五种细粒度状态，卡片和筛选菜单同步显示：

| 状态 | 描述 | 颜色 |
|------|------|------|
| `idle` | 空闲 | 灰色 |
| `running` | 运行中（开发服务器） | 绿色 |
| `installing` | 安装依赖中 | 蓝色 |
| `building` | 构建中 | 蓝色 |
| `compressing` | 压缩 dist 中 | 蓝色 |

### 快捷操作

- **在 Finder 中打开**：直接在 Finder 中定位项目目录
- **在编辑器中打开**：二级子菜单列出系统已安装的编辑器（VSCode、WebStorm、Cursor、Sublime Text、Nova），显示真实应用图标和名称。uni-app 项目在菜单顶部额外显示 HBuilderX，微信小程序项目在顶部额外显示微信开发者工具（需系统已安装）
- **在终端中打开**：通过 AppleScript 在 Terminal.app 中打开并 `cd` 到项目目录
- **刷新项目信息**：卡片菜单中支持单个项目的独立深度扫描（git + 磁盘占用），无需全局刷新
- **移到废纸篓**：安全删除项目（使用 `FileManager.trashItem`），支持从废纸篓恢复

### 批量操作

工具栏"更多"菜单提供：

- **删除所有构建**：批量删除所有项目的构建输出目录和压缩包，删除后立即刷新磁盘占用显示
- **删除所有依赖**：批量删除所有项目的 `node_modules`，删除后立即更新卡片标签和磁盘占用

### Git 克隆

通过"添加项目"弹窗输入 Git 仓库地址，自动克隆到项目集根目录并刷新项目列表。

### 终端日志面板

底部统一的深色终端风格面板，功能包括：

- 点击项目卡片上的日志按钮打开/切换/关闭面板
- 实时显示进程 stdout/stderr 输出
- 等宽字体 + 深色背景，模拟真实终端体验
- 自动滚动开关
- 日志清除功能
- 文本可选可复制
- LazyVStack 懒加载渲染 + 2000 行缓冲区上限，大量日志不卡顿

### 主题模式

支持浅色、深色、跟随系统三种主题，偏好设置持久化到 UserDefaults。

## 项目结构

```
Web Project Management/
├── Web Project Management.xcodeproj/
│   └── project.pbxproj
├── Web Project Management/
│   ├── WebProjectManagementApp.swift          # 应用入口，窗口配置与菜单栏命令
│   │
│   ├── Models/                                # 数据模型层
│   │   ├── Project.swift                      # Project 模型 + GitStatus + PackageManagerType 枚举
│   │   ├── ProjectStatus.swift                # 项目运行状态枚举（5 种状态）
│   │   └── FrameworkType.swift                # 前端框架类型枚举 + 标识色
│   │
│   ├── Core/                                  # 核心业务逻辑层
│   │   ├── AppState.swift                     # 全局状态管理（@Observable + projectsRevision）+ ThemeMode + EditorInfo
│   │   ├── LogStore.swift                     # 独立日志存储（按路径分代追踪，行缓冲区）
│   │   ├── ProjectProcessManager.swift        # Actor 进程管理器（AsyncStream 日志流）
│   │   └── ProjectScanner.swift               # 项目目录扫描器（框架/包管理器/Git/磁盘占用/构建目录识别）
│   │
│   ├── Views/                                 # SwiftUI 视图层
│   │   ├── ContentView.swift                  # 主内容视图 + 搜索筛选 Menu + 过滤缓存 + 工具栏 + 设置 + 弹窗
│   │   ├── ProjectCardView.swift              # 项目卡片（Equatable 优化 + 预计算参数）+ Git 状态 + 操作按钮
│   │   ├── LogDrawerView.swift                # 底部终端日志面板（LazyVStack 渲染）
│   │   ├── EmptyStateView.swift               # 首次启动引导视图（拖拽/选择目录）
│   │   └── AppBackgroundView.swift            # 窗口背景色
│   │
│   └── Assets.xcassets/                       # 资源文件
│       ├── AppIcon.appiconset/                # 应用图标
│       ├── AccentColor.colorset/              # 主题强调色
│       ├── vue.imageset/                      # Vue 框架图标
│       ├── react.imageset/                    # React 框架图标
│       ├── angular.imageset/                  # Angular 框架图标
│       ├── uniapp.imageset/                   # uni-app 框架图标
│       ├── uniappx.imageset/                  # uni-app x 框架图标
│       ├── weChatMiniProgram.imageset/        # 微信小程序图标
│       ├── html.imageset/                     # HTML 静态项目图标
│       └── gitbranch.imageset/                # Git 分支图标
│
├── .gitignore
├── README.md
└── CHANGELOG.md
```

## 构建与运行

### 环境要求

- macOS 26.5 或更高版本
- Xcode 16+（需支持 Swift 6 严格并发）

### 构建步骤

```bash
# 克隆仓库
git clone git@github.com:Hmm-nichijou/WebProjectManagement.git
cd "Web Project Management"

# 使用 xcodebuild 构建
xcodebuild -project "Web Project Management.xcodeproj" \
  -scheme "Web Project Management" \
  -configuration Debug \
  build
```

### 在 Xcode 中打开

```bash
open "Web Project Management.xcodeproj"
```

按 `Cmd+R` 即可运行。

### 注意事项

- **App Sandbox 已关闭**（`ENABLE_APP_SANDBOX = NO`）：应用需要通过 `Process` 执行 npm/pnpm/yarn/git 等外部命令，沙盒环境会阻止这些操作
- **Swift 6 严格并发**：项目启用了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所有类型默认隔离在主线程，跨 actor 访问需要显式标注 `@Sendable` 或使用 `Task.detached`
- **源文件自动包含**：使用 `PBXFileSystemSynchronizedRootGroup`，在源文件目录中新增的 `.swift` 文件会自动加入构建目标，无需手动编辑 `.pbxproj`

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+N` | 添加项目（Git 克隆） |
| `Cmd+O` | 选择项目目录 |
| `Cmd+R` | 刷新扫描 |
| `Cmd+F` | 聚焦搜索框 |
| `Cmd+,` | 打开设置 |

## 用户偏好持久化

应用通过 `UserDefaults` 持久化以下数据：

| 键名 | 类型 | 说明 |
|------|------|------|
| `savedRootDirectory` | `String` | 项目集根目录路径 |
| `savedCloudDriveURL` | `String` | 云盘网站 URL |
| `savedPinnedProjectIDs` | `Data` (JSON) | 置顶项目的绝对路径集合 |
| `savedThemeMode` | `String` | 主题模式（light/dark/system） |

## 性能优化策略

本应用在 SwiftUI macOS 开发中实施了多项性能优化：

- **日志分离渲染**：`LogStore` 独立于 `projects` 数组，日志追加不触发项目网格重算
- **行缓冲区 + LazyVStack**：日志按行存储为 `LogEntry` 数组，使用 `LazyVStack` + `ForEach` 懒加载渲染，2000 行上限自动裁剪旧行
- **Equatable 卡片**：`ProjectCardView` 通过 `Equatable` + `.equatable()` 跳过无关属性变化引起的 body 重算，编辑器信息作为预计算参数传入避免 `@Observable` 追踪污染
- **过滤缓存**：`filteredProjectsCache`（`@State`）缓存排序 + 过滤结果，`projectsRevision` 统一版本号追踪所有项目数据变更，滚动时零计算开销
- **两阶段扫描**：快速文件检测后立即展示列表，git 和磁盘操作通过 `withTaskGroup` 并发后台补充，卡片以"加载中"状态过渡
- **自适应卡片阴影**：使用 `.background(RoundedRectangle.fill().shadow())` 仅在背景形状上绘制阴影，避免 `.compositingGroup()` 的整卡离屏渲染开销
- **避免高开销修饰符**：不使用 `.ultraThinMaterial`（GPU 密集）、不使用 `repeatForever` 动画（窗口切换时卡顿）、静态图标替代 `ProgressView` 动画（防止多卡片同时动画引起布局抖动）
- **非动画滚动**：日志面板使用非动画 `scrollTo`，避免快速日志块堆积导致动画栈溢出
- **轮询消费**：UI 以 200ms 间隔轮询 `LogStore`，而非直接消费 `AsyncStream`，避免双消费者竞争

## 许可证

本项目仅供个人开发使用。
