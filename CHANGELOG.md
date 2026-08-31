# Changelog

## [1.2.3] - 2026-08-31

### 新增功能

- **打包格式切换**：构建压缩支持 `.zip` 和 `.tar.gz`（`tar -czvf archive.tar.gz`）两种格式，在"选择构建方式"气泡中通过 Tabs 样式 Picker 切换，切换即时生效并写入构建命令
- **打包格式按项目独立记录**：打包格式选择以项目路径为键持久化（`savedPackageFormatsByPath`），各项目互不影响；旧版全局格式 `savedPackageFormat` 自动迁移为默认值
- **压缩后删除构建文件夹**：设置页新增开关（默认关闭），构建压缩成功后自动删除构建输出文件夹（如 `dist`），压缩失败时不删除
- **H5 项目"打开"按钮**：HTML 静态项目卡片新增"打开"操作，直接在默认浏览器中打开项目目录下的 `index.html`（文件不存在时提示）

### 改进

- **"选择构建方式"改为 Popover 组件**：原 `confirmationDialog` 仅能渲染纯按钮列表，改用 Popover（`BuildOptionsPopover`）承载打包格式 Picker 与两种构建方式，按钮使用 `.glassProminent` / `.glass` 胶囊样式
- **全面应用液态玻璃（Liquid Glass）效果**：
  - 窗口背景改为 `glassEffect` 毛玻璃，随桌面壁纸产生折射与磨砂效果，自动适配浅色/深色外观
  - 项目卡片、状态指示器、搜索框、框架/状态筛选菜单（`GlassEffectContainer` + `.regular.interactive()`，按压反馈仅作用于被点击项）全部玻璃化
  - 设置与添加项目弹窗的输入框、按钮改为玻璃胶囊样式，隐藏窗口工具栏背景
  - 外观模式 Picker 从 `segmented` 改为 `tabs` 胶囊样式
- **最低系统要求提升至 macOS 27.0+**：因使用液态玻璃效果（`glassEffect`）重新设定部署目标
- **设置项实时生效**：云盘 URL、主题模式、"压缩后删除构建文件夹"等设置修改后立即持久化并生效，移除设置弹窗的"保存"按钮和草稿状态；云盘 URL 与 Git 地址输入框新增一键清除按钮
- **uni-app / uni-app x 项目隐藏运行和构建按钮**：与 unknown、微信小程序类型保持一致（`supportsRunBuild` 排除）
- **日志按钮稳定占位**：卡片日志按钮空闲时透明且不可点击，避免按钮出现/消失导致卡片高度抖动
- **编辑器菜单图标渲染**：`Label` 的 icon 参数改为 `HStack` + 16×16 缩放 `Image`，修复自定义 `NSImage` 应用图标的显示问题
- **磁盘占用统计**：压缩包大小同时统计 `dist.zip` 和 `archive.tar.gz` 两种格式

### Bug 修复

- **nvm 环境兼容**：`~/.nvm/versions/node/*/bin` 是 glob 通配符，`Process` 不经过 shell 不会展开，导致找不到 node。现手动解析实际安装的版本目录，读取 `~/.nvm/alias/default` 识别默认版本（支持 `lts/*` 别名引用），默认版本优先加入 `PATH`，其余版本兜底
- **窗口尺寸/位置无法记录**：SwiftUI `WindowGroup` 不会自动持久化窗口框架，`NSWindow.frameAutosaveName` 在窗口重建时存在名称冲突。新增 `WindowFrameAutosaver` 通过 UserDefaults + `didMove`/`didResize` 通知手动保存和恢复窗口框架（恢复时校验不小于最小尺寸）
- **"跟随系统"外观切换不及时**：`.preferredColorScheme` 无法即时回退主窗口外观（应用级 `NSApp.appearance` 可能被此前的深色模式锁定）。新增 `WindowAppearanceSyncer` 直接同步控制 `NSApp.appearance` + `window.appearance`，"跟随系统"时同时清空两级外观
- **切换打包格式后旧压缩包残留**：快速构建前先删除当前项目所有格式（`.zip` 与 `archive.tar.gz`）的构建压缩物；"删除所有构建"批量操作同样清理两种格式
- **终端日志面板新增 Esc 快捷键关闭**：关闭按钮绑定 `keyboardShortcut(.escape)`

## [1.2.2] - 2026-06-30

### 新增功能

- **项目卡片独立刷新**：卡片"更多"菜单新增"刷新项目信息"选项，支持单个项目深度扫描（git + 磁盘占用），无需全局刷新
- **构建输出目录动态检测**：读取 `vite.config.ts/js/mjs` 中的 `build.outDir` 配置，构建、压缩、清除构建物均使用项目实际的输出目录名（默认 `dist`），支持自定义构建目录
- **搜索栏液态玻璃效果**：搜索框使用 `.regularMaterial` 背景 + 圆角 + 半透明边框，实现类玻璃磨砂效果

### 改进

- **两阶段扫描架构**：全局扫描改为快速展示 + 后台补充。第一阶段文件检测后立即展示项目列表，卡片显示"加载中"状态；第二阶段并发补充 git 分支/状态和磁盘占用数据，逐卡片更新
- **工具栏菜单重构**：合并"删除所有构建"和"删除所有依赖"到"更多"下拉菜单，替换菜单图标为 `ellipsis`
- **设置页布局优化**：外观模式选项从纵向改为横向排版，与标签同行显示
- **弹窗按钮玻璃态**：设置和添加项目弹窗的按钮添加 `.glass` / `.glassProminent` 样式
- **卡片加载状态**：深度扫描未完成时显示静态 `circle.dashed` 图标 + "加载中"文字，替代 `ProgressView` 动画（避免多卡片同时动画引起滚动卡顿）
- **卡片阴影优化**：移除 `.compositingGroup()`（整卡离屏渲染开销大），改为 `.background(RoundedRectangle.fill().shadow())`，阴影仅作用于背景形状
- **编辑器显示名称本地化**：使用 `FileManager.displayName(atPath:)` 获取系统本地化名称，与 Finder 中显示一致
- **批量删除即时刷新**：删除所有构建/依赖后，立即更新项目结构体中的磁盘占用数据并刷新 UI，无需等待下次扫描

### 性能优化

- **过滤缓存**：`filteredProjects` 从计算属性改为 `@State` 缓存，通过 `.onChange` 监听搜索文本、筛选条件、`projectsRevision` 重建，滚动时不再重复执行排序 + 过滤
- **统一版本号计数器**：`projectsRevision` 统一追踪所有项目数据变更（列表增减、置顶、状态变更、批量操作），替代原先分散的 `sortedProjectsCache` + `statusRevision`
- **卡片 Equatable 增强**：`ProjectCardView` 的 `==` 比较增加 `gitBranch`、`frameworkType`、`packageManager` 字段，确保这些属性变化时卡片正确重渲染
- **@Observable 追踪隔离**：卡片参数改为预计算值传入（`hasEditors`、`hbuilderxInfo`、`wechatDevToolsInfo`），避免卡片 body 中直接读取 `@Observable` 属性导致 Equatable 优化失效
- **PinButton 动画简化**：`.animation(.easeInOut, value:)` 改为 `onHover { withAnimation {} }`，减少滚动时的动画追踪开销

### 代码优化

- `AppState` 全面重构：移除 `sortedProjectsCache` 和 `rebuildSortedProjects()`，合并为 `projectsRevision` 统一计数器
- 新增 `updateProjectStatus()` 方法统一处理状态赋值 + 版本号递增，消除 11 处重复代码
- `Project.isEnriched`、`hasNodeModules`、`nodeModulesSize`、`distSize`、`distZipSize` 从 `let` 改为 `var`，支持批量操作后原地更新
- `refreshProject` 从完整结构体重建简化为 `projects[idx].isEnriched = false` 一行
- `savePinnedPaths()` 提取为私有方法复用
- `ThemeMode` 枚举体使用 switch 表达式简化
- `Project` 和 `ProjectStatus` 添加 `Equatable` 协议遵循

## [1.2.1] - 2026-06-24

### 改进

- **app 图标修改**：使用 Icon Composer 制作 Liquid Glass 风格图标

## [1.2] - 2026-06-24

### 新增功能

- **Git 状态指示器**：卡片实时显示项目的 Git 工作区状态，包括修改、未跟踪文件数，以及与远程分支的 ahead/behind 提交数。使用线性风格图标（pencil.line、questionmark、arrow.up、arrow.down），工作区干净时不显示任何图标
- **磁盘占用统计**：信息栏汇总展示所有项目的 node_modules、dist、dist.zip 总磁盘占用，使用 `ByteCountFormatter` 格式化为可读大小
- **主题模式切换**：支持浅色、深色、跟随系统三种模式，通过设置面板切换，偏好持久化到 UserDefaults。全局使用语义色（`Color(.controlBackgroundColor)`、`.primary`、`.secondary`）适配深色模式
- **uni-app / uni-app x 项目支持**：基于特征文件检测（`manifest.json` + `pages.json`），兼容文件在根目录或 `src` 子目录的情况。uni-app x 通过 `manifest.json` 中的 `"uni-app-x"` 节点识别。uni-app 项目隐藏运行和构建按钮，在"编辑器中打开"菜单中集成 HBuilderX
- **微信小程序项目支持**：检测 `miniprogram/pages/` 目录下是否存在 `.wxml` 文件（支持递归查找），自动识别为微信小程序项目。微信小程序和未知类型项目隐藏运行和构建按钮，在"在编辑器中打开"二级菜单中集成微信开发者工具
- **微信开发者工具集成**：通过 Spotlight 检测系统是否安装微信开发者工具（`com.tencent.webplusdevtools`），已安装时在微信小程序项目的"在编辑器中打开"二级菜单顶部显示，可直接打开项目
- **取消构建操作**：构建/安装/压缩过程中可点击"取消构建"终止操作，启停按钮独立于构建状态，构建期间仍可启停开发服务器
- **未知项目类型兼容**：无法识别的项目不再跳过，保留在列表中显示，类型图标不展示
- **node_modules 安装标签**：已安装 node_modules 的项目显示绿色胶囊标签，未安装则不显示

### 改进

- **筛选交互重构**：框架类型和运行状态筛选从平铺的 FilterChip 标签改为 Menu 下拉菜单，按类型分组，选中状态在按钮上实时体现
- **HBuilderX 菜单位置**：从独立按钮整合到"在编辑器中打开"二级菜单中，仅在 uni-app 项目中显示，用分隔线与其他编辑器区分
- **uni-app 检测方式**：从基于 npm 依赖判断改为基于特征文件检测（`manifest.json` + `pages.json`），更准确可靠
- **AnimatedBackgroundView 重命名**：重命名为 `AppBackgroundView`，更准确反映其当前用途
- **Git 状态图标风格统一**：所有图标统一使用线性风格，图标与数值之间无间距，不同状态组之间保持间隔
- **卡片阴影效果**：项目卡片添加自适应阴影（`Color.primary.opacity(0.08)`），浅色模式下为暗色阴影，深色模式下为微弱亮色光晕，清晰区分卡片边界
- **操作按钮权限控制**：通过 `FrameworkType.supportsRunBuild` 属性统一控制运行/构建按钮的显示，unknown 和微信小程序类型不展示这些按钮
- **编辑器显示名称本地化**：编辑器菜单中的名称改为使用 `FileManager.displayName(atPath:)` 获取系统本地化名称，与 Finder 中显示一致（如"微信开发者工具"而非"wechatwebdevtools"）

### Bug 修复

- **筛选菜单空图标错误**：修复框架类型筛选菜单中未选中项传入空字符串作为 SF Symbol 名称导致的 "No symbol named '' found in system symbol set" 运行时错误，改为条件渲染（选中时显示 `Label` + checkmark，未选中时显示纯 `Text`）

### 代码优化

- 移除 `Session.log` 死存储属性（`ProjectProcessManager`），该属性持续累加但从未被读取
- 移除 `Project.hasScripts` 未使用计算属性
- 移除 `LogStore.log(for:)` 未使用方法
- 合并 `ProjectStatus.iconColor` 和 `color` 重复属性为统一的 `color`
- 修复 `ProjectScanner` 对 `package.json` 的重复读取，改为一次解析复用结果
- 移除 `ProjectStatus` 未使用的 `CaseIterable` 协议遵循
- 移除 `EmptyStateView` 未使用的 `import UniformTypeIdentifiers`
- 简化 `PackageManagerType.tagTextColor`，消除冗余的 switch 语句
