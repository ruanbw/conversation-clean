# ConversationClean (macOS)

基于 Swift 6 + SwiftUI 构建的现代化 macOS 原生应用模板，开箱即用。

---

## 🌟 项目特性

- **现代 macOS 设计规范**：采用 `NavigationSplitView` 双栏布局、统一工具栏（Unified Toolbar）、原生 SF Symbols 图标体系。
- **清晰的 MVVM 架构**：
  - `Models/`：数据模型（`ConversationItem`、`ConversationCategory`）。
  - `ViewModels/`：业务状态管理（`CleanViewModel`，基于 `@MainActor` 与 Combine）。
  - `Views/`：界面组件分离（侧边栏 `SidebarView`、内容栏 `DetailView`、偏好设置 `SettingsView`）。
- **完善的交互体验**：
  - 搜索与分类过滤（`.searchable`）。
  - 会话多选与全选批量清理操作。
  - 异步模拟扫描与清理状态提示（Progress / Alert）。
  - 原生 Preferences 设置窗口（`Settings { ... }` 与 `@AppStorage`）。
- **标准 Xcode 工程**：自带完整的 `ConversationClean.xcodeproj` 与共享构建 Scheme，无需额外安装第三方脚手架。
- **App Sandbox**：预置标准 `.entitlements` 权限配置。

---

## 📁 目录结构

```text
conversation-clean/
├── .gitignore                                  # macOS / Xcode 专用忽略规则
├── README.md                                   # 项目说明文档
├── ConversationClean.xcodeproj/                # Xcode 工程与 Scheme 配置
└── ConversationClean/                          # 源代码主目录
    ├── ConversationCleanApp.swift              # App 启动入口与窗口生命周期
    ├── ContentView.swift                       # 根视图 (NavigationSplitView)
    ├── Models/
    │   └── ConversationItem.swift              # 会话数据模型与枚举
    ├── ViewModels/
    │   └── CleanViewModel.swift                # 状态与业务逻辑 ViewModel
    ├── Views/
    │   ├── SidebarView.swift                   # 侧边栏与缓存概览
    │   ├── DetailView.swift                    # 会话列表与批量操作栏
    │   └── SettingsView.swift                  # 偏好设置面板
    ├── Assets.xcassets/                        # 图标与配色资源
    └── ConversationClean.entitlements          # 沙盒与权限声明
```

---

## 🚀 快速上手

### 1. 使用 Xcode 打开

直接双击工程文件或在终端执行：

```bash
open ConversationClean.xcodeproj
```

在 Xcode 中选择目标设备为 **My Mac**，按下快捷键 `Cmd + R` 即可运行。

### 2. 命令行编译与测试

在项目根目录下执行：

```bash
xcodebuild -scheme ConversationClean -configuration Debug build
```

---

## 🛠️ 技术要求

- **macOS**：14.0 (Sonoma) 及以上
- **Xcode**：15.0+ / 16.0+
- **Swift**：5.9+ / 6.0+
