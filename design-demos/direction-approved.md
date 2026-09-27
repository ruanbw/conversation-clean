# Direction Approval · 主界面 UI 重构

## 日期
2026-09-27（App 图标那轮之后的第二次三方向门）

## 任务背景
用户反馈「ui 太丑了」。诊断出 6 个硬伤：三栏同色无材质分层、分布条用 `Color.primary.opacity()`
黑灰 ramp（深色模式下变白条）、侧栏 500pt 空白、中栏右侧数字墙 + 62pt 不可见会话 ID 列、
自绘顶栏像网页、`.tint(.red)` + `.disabled` 渲染成粉红。
用户点名的 3 个最不能忍：**配色太单调 / 太松散留白多 / 数据可视化难看**。

## 硬约束（用户明确指令，不可违背）
- **禁止使用原生 UI 控件**：不用 NSToolbar / NavigationSplitView / 系统 List、Toggle、
  Button、Picker、Form、TextField。全部手绘。
- 保留 `.windowStyle(.hiddenTitleBar)` + 手搓三栏 + 手搓顶栏，红绿灯继续浮在自有背景上。
- 视觉调性：**浅色精致 + 克制强调色**（用户选定）。
  底 `#FAFAFB` / 面 `#FFFFFF` / 发丝线 `#E9E9ED` / 强调 `#5B5BD6→#7C7CF0` /
  危险 `#E5484D` / 成功 `#30A46C`。

## 展示了哪几版（三方向硬门，全部为可交互 HTML + Playwright 截图）
- **方向 A — 精密密度**（逻辑二：现实参照 = Linear 设计系统）
  - 截图：`design-demos/ui-a-precision.png`
  - HTML：`design-demos/ui-a-precision.html`（可点：行选中 / 勾选 / 侧栏切换）
  - 要点：32pt 行高、去会话 ID 列、体积 12.5pt semibold 提到比标题更重、
    2pt 靛蓝竖条选中态、靛蓝 6 阶（同 hue 明度阶梯）分布 + 横条列表、
    侧栏加「可回收空间」体检卡填掉 500pt 空白。
- **方向 B — 材质呼吸**（逻辑三：最佳设计师 = Apple HIG）
  - 截图：`design-demos/ui-b-material.png`
  - HTML：`design-demos/ui-b-material.html`
  - 要点：40pt 两行制、14pt display 体积号、34px 渐变大字体检卡、材质分层、10pt 圆角。
- **方向 C — 体积优先**（数据驱动 = DaisyDisk 面积即体积）
  - 截图：`design-demos/ui-c-volumetric.png`
  - HTML：`design-demos/ui-c-volumetric.html`
  - 要点：体积移到行首做主视觉、行底纹宽度=占比、矩形树图。
    小占比 Agent 用固定区并明确标注「块面积不按比例」——0.6% 画出 10% 的块是撒谎。

## 用户选择原话
> A 精密密度（推荐）

（完整选择：方向 = 全自绘所有控件 / 调性 = 浅色精致 + 克制强调色 / 基线 = A 精密密度）

## 选定方向
**方向 A — 精密密度**（Linear 系）

## 设计系统来源（非凭空）
| 来源 | 采用的 token |
|---|---|
| Linear 设计系统 | 主色 `#5e6ad2`（= 靛蓝基底）、发丝线 `#e9e9ed`、四级表面梯、无行分隔线改留白 |
| Apple HIG | 8pt baseline grid（1/4/6/8/12/16/20/24/32）、窗口圆角 10pt、控件圆角 6-8pt、正文 13pt（macOS 非 iOS 值） |
| DaisyDisk | 面积即体积的诚实可视化原则 |
| Raycast | fast / simple / delightful |

## 修掉的 6 个硬伤
1. 三栏分层：侧栏 `--sidebar #F6F6F8` / 中栏 `--surface #FFF` / 右栏 `--bg`，发丝线分隔
2. 分布配色：`Color.primary.opacity()` 黑灰 ramp → 靛蓝 6 阶明度阶梯（深浅色都可辨）
3. 侧栏空白：加「可回收空间」体检卡 + 靛蓝存储路径卡，填成有用信息
4. 中栏数字墙：删 62pt 会话 ID 列，体积独占 52pt，占比改 5pt 迷你条
5. 顶栏：改用自绘按钮组件（6pt 圆角 + 自有 hover/press + 靛蓝渐变主按钮）
6. 禁用水粉红：危险按钮自绘，禁用态走 opacity 而非系统 tint

## 附带修正的层级错误
原实现中标题 `.body.weight(.medium)`(13pt) 比体积 `.callout.weight(.semibold)`(12pt) 更重。
在「清理 99MB 垃圾」的工具里这是反的——体积才该是第一视觉层级。A 版把体积提到比标题更重。
