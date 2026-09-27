#!/usr/bin/env python3
"""
UI 自绘改造验收检查
================================================================
这次改造的目标是「零系统 UI 控件 + token 化」。这两件事靠肉眼没法验收，
所以把判定写成脚本。每一项都应该为 0。

为什么要剥离注释再做检测：
  改造过程中每处改动都留了「这里原来用的是系统 XXX」的说明性注释，
  naive 的 grep 会把 `Picker(` / `ContentUnavailableView` / `#5B5BD6` 这些
  注释里的关键词全判成残留 —— 第一版脚本就是这么误报的。
  所以先剥字符串字面量、再剥 `//` 与 `/* */` 注释，只对真实代码判定。

用法：python3 scripts/check_ui_selfdraw.py
退出码 0 = 全过。
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
VIEWS = ROOT / "ConversationClean" / "Views"
# Theme / DrawnControls 是 token 与控件定义本身，字面量出现在那里是应该的
EXEMPT_FILES = {"Theme.swift", "DrawnControls.swift"}
# AgentIconView 里那三个 Color(red:...) 是 15 款 Agent 的官方品牌色。
# 品牌标识色不是 UI token —— 它们必须精确等于官方色值，跟随主题反而错。
EXEMPT_COLOR_FILES = EXEMPT_FILES | {"AgentIconView.swift"}

failures: list[tuple[str, list[str]]] = []
current_section = ""


def section(name: str) -> None:
    global current_section
    current_section = name
    print(f"\n\033[1m── {name}\033[0m")


def check(label: str, hits: list[str], ok_hint: str = "") -> None:
    hits = [h for h in hits if h.strip()]
    if not hits:
        print(f"  \033[32m✓\033[0m {label}")
    else:
        print(f"  \033[31m✗ {len(hits)} 处\033[0m {label}")
        for h in hits[:8]:
            print(f"      \033[90m{h}\033[0m")
        if len(hits) > 8:
            print(f"      \033[90m… 另有 {len(hits) - 8} 处\033[0m")
        failures.append((f"{current_section} · {label}", hits))


# ── 源码加载与注释剥离 ────────────────────────────────────────────────────────

def strip_noise(src: str) -> str:
    """剥掉字符串字面量与注释，只留真实代码。同行注释也一起剥。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':                      # 字符串（含插值不做求值，直接跳过）
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
        elif src.startswith("//", i):     # 行注释，剥到行尾
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):     # 块注释（可跨行）
            depth, i = 0, i
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    # 关键：注释里的换行要原样吐回去，否则删除后行号偏移，
                    # 报出来的行号会指到无关的代码上（证据不准就等于没证据）
                    if src[i] == "\n":
                        out.append("\n")
                    i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def strip_exempt(src: str) -> str:
    """剥掉显式豁免块：`// selfdraw-exempt: begin` … `end` 之间的内容。

    为什么要豁免：右键菜单（以及任何交给系统 Menu 渲染的区域）本身就是系统 UI，
    菜单项的图标 / 文字 / Divider 分隔线**应该**跟系统，把它们换成自绘发丝线
    只会让菜单看起来是坏的。

    不用启发式（花括号配对 / 缩进猜测）是因为不可靠：`.contextMenu { rowMenu(item) }`
    这种 ViewBuilder 写法花括号根本配对不上。这里改成显式成对标记 ——
    规则可读、可审计，而且豁免哪里由写代码的人明确声明，不是猜的。

    标记必须在剥注释**之前**处理（它本身就是注释）。"""
    out, i, n = [], 0, len(src)
    begin_rx = re.compile(r"//\s*selfdraw-exempt:\s*begin")
    end_rx = re.compile(r"//\s*selfdraw-exempt:\s*end")
    while i < n:
        m = begin_rx.search(src, i)
        if not m:
            out.append(src[i:])
            break
        out.append(src[i:m.start()])
        end = end_rx.search(src, m.end())
        stop = end.end() if end else n
        # 保留换行以维持行号
        out.append("\n" * src.count("\n", m.start(), stop))
        i = stop
    return "".join(out)


def code_files(subset=None):
    files = sorted((VIEWS).glob("*.swift")) if subset is None else subset
    loaded = []
    for p in files:
        raw = p.read_text(encoding="utf-8")
        # 豁免块在剥注释之前处理：标记本身是注释
        loaded.append((p, raw, strip_noise(strip_exempt(raw))))
    return loaded


def loc(code: str, index: int, path: pathlib.Path) -> str:
    # 必须用**剥离后**的 code 数行号：index 是 code 里的下标。
    # strip_noise 保留了换行，所以 code 与原文件行号一一对应。
    # （拿原始字符串去数会把注释删除造成的字符偏移算成行偏移，行号全错。）
    line = code.count("\n", 0, index) + 1
    return f"{path.relative_to(ROOT)}:{line}"


def scan(files, pattern, exclude_files=frozenset(), flags=0):
    """在剥离注释后的代码里搜正则，命中返回 'file:line' 列表。"""
    rx = re.compile(pattern, flags)
    hits = []
    for path, _raw, code in files:
        if path.name in exclude_files:
            continue
        for m in rx.finditer(code):
            hits.append(loc(code, m.start(), path))
    return hits


VIEWS_ALL = code_files()
VIEWS_CODE = code_files([p for p, _, _ in VIEWS_ALL if p.name not in EXEMPT_FILES])
ALL_SWIFT = code_files(sorted((ROOT / "ConversationClean").rglob("*.swift")))

# ══════════════════════════════════════════════════════════════════════════════
section("1 · 系统 UI 控件残留（目标 0）")
# ══════════════════════════════════════════════════════════════════════════════
check("系统 Form", scan(VIEWS_CODE, r"(?<![\w.])Form\s*\{"))
check("系统 List", scan(VIEWS_CODE, r"(?<![\w.])List\s*[\{\(]"))
check("系统 ContentUnavailableView", scan(VIEWS_CODE, r"ContentUnavailableView"))
check("系统 Picker", scan(VIEWS_CODE, r"(?<![\w.])Picker\s*\("))
check("系统 pickerStyle", scan(VIEWS_CODE, r"\.pickerStyle\s*\("))
# Toggle 只在「有 label 的系统 Toggle」算残留；纯值绑定 + 自绘外观是允许的
check("系统 Toggle（有 label）", scan(VIEWS_CODE, r"(?<![\w.])Toggle\s*\([^)]*\)\s*\{"))
check("LabeledContent / GroupBox / Stepper / Slider",
      scan(VIEWS_CODE, r"LabeledContent|(?<![\w.])GroupBox\s*\{|(?<![\w.])Stepper\s*\(|(?<![\w.])Slider\s*\("))
check("裸 Divider()", scan(VIEWS_CODE, r"(?<![\w.])Divider\s*\(\s*\)"))
# 只报系统的 toggleStyle；DrawnSwitchStyle 等自绘样式不算残留
check("系统 toggleStyle / listStyle",
      scan(VIEWS_CODE, r"\.toggleStyle\s*\(\s*\.(switch|checkbox|button)|\.listStyle\s*\("))

# Button 必须在它的作用域内接上 .buttonStyle(...)。
#
# 作用域的划定不能用「往后 N 个字符」：SwiftUI 的 label 可以嵌套很深
# （Button → HStack → VStack → Text → modifier…），label 里任意一处深嵌套都会把
# .buttonStyle 顶到几百字符之外，固定窗口必然误报。
# 正确做法是「到下一个 Button( 出现为止」—— 下一个 Button 之前出现的
# .buttonStyle 只可能属于当前这个 Button。
btn_hits = []
btn_rx = re.compile(r"(?<![\w.])Button\s*[(\s]")
for path, _raw, code in VIEWS_ALL:
    if path.name in EXEMPT_FILES:
        continue
    starts = [m.start() for m in btn_rx.finditer(code)]
    style_rx = re.compile(r"\.buttonStyle\s*\(")
    for idx, start in enumerate(starts):
        end = starts[idx + 1] if idx + 1 < len(starts) else len(code)
        if not style_rx.search(code, start, end):
            btn_hits.append(loc(code, start, path))
check("Button 未接 buttonStyle", btn_hits)

# ══════════════════════════════════════════════════════════════════════════════
section("2 · 硬编码颜色（目标 0）")
# ══════════════════════════════════════════════════════════════════════════════
check("Color(red:/white:/hue:) 字面量",
      scan(VIEWS_CODE, r"Color\s*\(\s*(red|white|hue)\s*:", EXEMPT_COLOR_FILES))
check("十六进制色值", scan(VIEWS_CODE, r"#[0-9A-Fa-f]{6}\b", EXEMPT_FILES))
check("系统语义色（windowBackground / controlBackground / quaternaryLabel / separator）",
      scan(ALL_SWIFT, r"windowBackgroundColor|controlBackgroundColor|quaternaryLabelColor|"
                      r"separatorColor|labelColor|systemGroupingBackground|underPageBackground"))

# ══════════════════════════════════════════════════════════════════════════════
section("3 · 数据可视化配色（目标 0）")
# ══════════════════════════════════════════════════════════════════════════════
# 这条是本次改造的核心修复：Color.primary.opacity() 做数据配色，
# 浅色下渲染成黑条、深色下整条变白条，且相邻段肉眼分不出。
# 所以只对「喂给 fill/条/段/图表」的 primary.opacity 判残留；
# 拿去当 hover 反馈底色是合法的。
check("数据可视化里用 Color.primary.opacity",
      scan(VIEWS_CODE,
           r"\.fill\s*\(\s*Color\.primary\.opacity[^)]*\)\s*\)?\s*$|"
           r"\.fill\s*\(\s*Color\.primary\.opacity",
           EXEMPT_FILES, re.MULTILINE))
check("本地灰阶 ramp 定义", scan(VIEWS_CODE, r"\bramp\b\s*[:=]|\blet ramp\b"))
check("数据段用 primary/secondary 灰阶",
      scan(VIEWS_CODE, r"(fill|foregroundStyle)\s*\(?\s*(Color\.)?(primary|secondary)\.opacity\([^)]*\)\s*\)?\s*\)?\s*$",
           EXEMPT_FILES, re.MULTILINE))

# ══════════════════════════════════════════════════════════════════════════════
section("4 · 排版 token 化（目标 0）")
# ══════════════════════════════════════════════════════════════════════════════
# 只报正文字号。**SF Symbol 图标的字号要豁免**：
# `Image(systemName: "x").font(.system(size: 11))` 是图标按框缩放的固定字号，
# 换成语义字体（.body/.caption）会让 SF Symbol 字形跟着系统字号缩放，
# 破坏「图标与文字比例不变」这个约定。正文字号才必须走 Theme.Typo。
icon_rx = re.compile(
    r"Image\s*\(\s*systemName\s*:[^)]*\)"          # Image(systemName: …)
    r"[\s\S]{0,200}?"                                  # 可插少量修饰符
    r"\.font\s*\(\s*\.system\s*\(\s*size\s*:\s*[0-9]"
)


def _spans(pat, text):
    return [(m.start(), m.end()) for m in pat.finditer(text)]


def in_icon_context(code: str, start: int) -> bool:
    """该位置的字号是否属于一个 SF Symbol 图标。"""
    return any(a <= start < b for a, b in _spans(icon_rx, code))


hits = []
raw_rx = re.compile(r"\.font\s*\(\s*\.system\s*\(\s*size\s*:\s*[0-9]")
for path, _raw, code in VIEWS_ALL:
    if path.name in EXEMPT_FILES:
        continue
    for m in raw_rx.finditer(code):
        if not in_icon_context(code, m.start()):
            hits.append(loc(code, m.start(), path))
check("正文字面量 .font(.system(size: N))（图标字号已豁免）", hits)
check("系统语义字体",
      scan(VIEWS_CODE, r"\.font\s*\(\s*\.(body|callout|subheadline|caption|caption2|footnote|"
                       r"headline|title2|title3|title|largeTitle)\b"))

# ══════════════════════════════════════════════════════════════════════════════
section("5 · 间距与圆角 token 化（目标 0）")
# ══════════════════════════════════════════════════════════════════════════════
# HIG 8pt baseline：允许 1/2/4/6/8/10/12，其余必须走 Theme.Space
check("非 8pt-grid 的 padding 字面量",
      scan(VIEWS_CODE, r"\.padding\s*\(\s*((1[3-9]|[2-9][0-9]|[0-9]{3})(?![0-9.]))"))
check("圆角字面量", scan(VIEWS_CODE, r"cornerRadius\s*:\s*[0-9]"))

# ══════════════════════════════════════════════════════════════════════════════
section("6 · 分隔线不得覆盖父视图（实机踩过的坑）")
# ══════════════════════════════════════════════════════════════════════════════
# `.overlay(alignment:) { Rectangle().fill(...) }` 里 Rectangle 没有 frame 约束，
# 它会填满整个父视图，把内容全部盖死。若 Rectangle 恰好是父视图的背景色系
# （Theme.line 与 Theme.bg 只差 1 个色阶），视觉上就是「那里什么都没有」。
#
# 真实事故：顶栏 48pt 全白、批量条 44pt 消失，两处都是这一行导致的。
# 前几轮「零系统控件 + 零硬编码颜色」全绿也没拦住它 —— 所以单独立一条检查。
# 合法写法：带 .frame(...) 的 Rectangle，或直接用 Theme.swift 的 hairline()。
unframed = []
ov_rx = re.compile(
    r"\.overlay\s*\(\s*alignment\s*:[^)]*\)\s*\{\s*"
    r"Rectangle\s*\(\s*\)\s*\.fill\s*\([^)]*\)\s*(?!\.frame)"
)
for path, _raw, code in VIEWS_ALL:
    if path.name in EXEMPT_FILES:
        continue
    for m in ov_rx.finditer(code):
        unframed.append(loc(code, m.start(), path))
check("overlay 里的无框 Rectangle（会盖住整个父视图）", unframed)

# `Edge.Set.vertical` / `.horizontal` 是**集合**（== [.top,.bottom] / [.leading,.trailing]），
# 不是单个 edge，所以 `someEdgeSet.contains(.vertical)` 恒为 false（已实测）。
# 拿它算 frame 尺寸会得到 nil，Rectangle 照样填满父视图 —— 本次实机事故的直接原因。
misuse = []
mis_rx = re.compile(r"\.contains\s*\(\s*\.(vertical|horizontal)\s*\)")
for path, _raw, code in VIEWS_ALL:
    for m in mis_rx.finditer(code):
        misuse.append(loc(code, m.start(), path))
check("Edge.Set 误用 contains(.vertical/.horizontal)", misuse)

# ══════════════════════════════════════════════════════════════════════════════
section("7 · 可访问性不退化")
# ══════════════════════════════════════════════════════════════════════════════
a11y = scan(VIEWS_ALL, r"accessibility(Label|Value|Element|Hidden|AddTraits)")
if a11y:
    print(f"  \033[32m✓\033[0m 保留 {len(a11y)} 处可访问性标注")
else:
    check("自绘后应保留 VoiceOver 标注", ["<无>"])

# ══════════════════════════════════════════════════════════════════════════════
section("8 · 工程文件")
# ══════════════════════════════════════════════════════════════════════════════
pbx = (ROOT / "ConversationClean.xcodeproj" / "project.pbxproj").read_text()
for name in ("Theme.swift", "DrawnControls.swift"):
    check(f"{name} 已注册进 Sources 阶段",
          [] if f"{name} in Sources" in pbx else ["<未找到>"])

# ══════════════════════════════════════════════════════════════════════════════
print()
if not failures:
    print("\033[32m\033[1m全部通过\033[0m — 零系统控件、零硬编码颜色、数据可视化已上 token")
    sys.exit(0)
else:
    print(f"\033[31m\033[1m{len(failures)} 项有残留\033[0m")
    for title, _ in failures:
        print(f"  · {title}")
    sys.exit(1)
