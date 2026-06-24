# Changelog

## [1.2] - 2026-06-24

### 新增功能

- **Git 状态指示器**：卡片实时显示项目的 Git 工作区状态，包括修改、未跟踪文件数，以及与远程分支的 ahead/behind 提交数。使用线性风格图标（pencil.line、questionmark、arrow.up、arrow.down），工作区干净时不显示任何图标
- **磁盘占用统计**：信息栏汇总展示所有项目的 node_modules、dist、dist.zip 总磁盘占用，使用 `ByteCountFormatter` 格式化为可读大小
- **主题模式切换**：支持浅色、深色、跟随系统三种模式，通过设置面板切换，偏好持久化到 UserDefaults。全局使用语义色（`Color(.controlBackgroundColor)`、`.primary`、`.secondary`）适配深色模式
- **uni-app / uni-app x 项目支持**：基于特征文件检测（`manifest.json` + `pages.json`），兼容文件在根目录或 `src` 子目录的情况。uni-app x 通过 `manifest.json` 中的 `"uni-app-x"` 节点识别。uni-app 项目隐藏运行和构建按钮，在"编辑器中打开"菜单中集成 HBuilderX
- **微信小程序项目支持**：检测 `miniprogram/pages/` 目录下是否存在 `.wxml` 文件（支持递归查找），自动识别为微信小程序项目
- **取消构建操作**：构建/安装/压缩过程中，构建按钮变为红色的"取消构建"，点击可终止当前进程。启停按钮独立于构建状态，构建期间仍可启停开发服务器
- **未知项目类型兼容**：无法识别的项目不再跳过，保留在列表中显示，类型图标不展示

### 改进

- **筛选交互重构**：框架类型和运行状态筛选从平铺的 FilterChip 标签改为 Menu 下拉菜单，按类型分组，选中状态在按钮上实时体现
- **HBuilderX 菜单位置**：从独立按钮整合到"在编辑器中打开"二级菜单中，仅在 uni-app 项目中显示，用分隔线与其他编辑器区分
- **uni-app 检测方式**：从基于 npm 依赖判断改为基于特征文件检测（`manifest.json` + `pages.json`），更准确可靠
- **AnimatedBackgroundView 重命名**：重命名为 `AppBackgroundView`，更准确反映其当前用途
- **Git 状态图标风格统一**：所有图标统一使用线性风格，图标与数值之间无间距，不同状态组之间保持间隔
- **卡片阴影效果**：项目卡片添加自适应阴影（`Color.primary.opacity(0.08)`），浅色模式下为暗色阴影，深色模式下为微弱亮色光晕，清晰区分卡片边界
- **卡片阴影性能优化**：阴影前添加 `.compositingGroup()` 扁平化视图层级，减少阴影半径至 4，避免多卡片场景下的渲染卡顿

### Bug 修复

- **筛选菜单空图标错误**：修复框架类型筛选菜单中未选中项传入空字符串作为 SF Symbol 名称导致的 "No symbol named '' found in system symbol set" 运行时错误，改为条件渲染（选中时显示 `Label` + checkmark，未选中时显示纯 `Text`）

### 代码优化

- 移除 `Session.log` 死存储属性（`ProjectProcessManager`），该属性持续累加但从未被读取
- 移除 `Project.hasNodeModules` 未使用属性及其在扫描器中的检测逻辑
- 移除 `Project.hasScripts` 未使用计算属性
- 移除 `LogStore.log(for:)` 未使用方法
- 合并 `ProjectStatus.iconColor` 和 `color` 重复属性为统一的 `color`
- 修复 `ProjectScanner` 对 `package.json` 的重复读取，改为一次解析复用结果
- 移除 `ProjectStatus` 未使用的 `CaseIterable` 协议遵循
- 移除 `EmptyStateView` 未使用的 `import UniformTypeIdentifiers`
- 简化 `PackageManagerType.tagTextColor`，消除冗余的 switch 语句
