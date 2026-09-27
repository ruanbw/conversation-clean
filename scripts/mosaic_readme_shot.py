#!/usr/bin/env python3
"""给 README 截图打码。

坐标以「缩略视图」为基准写（1100 宽），再按实际像素比例放大到 Retina 原图，
换一台机器、窗口尺寸变一点也不用重算。

打码范围 = 用户真实数据：会话标题（就是首条 user prompt 原文）、项目路径、会话 ID。
Agent 名称、字节数、相对时间这些留着 —— 它们是这张图要展示的信息本身。
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

VIEW_W, VIEW_H = 1280, 820  # 缩略基准（= 窗口 point 尺寸，1:1 好核对）
BLOCK = 11                 # 马赛克块边长（最终像素）

# 三条分隔条在 VIEW_W 坐标系里的预期边界。用来在打码前校验截图栏宽，
# 不一致就直接报错停下。
#
# [坑] 这里踩过坑，而且 **Electron 移植后又踩了一次**：
# 列宽存在 localStorage（sidebarWidth / listWidth）里，是**用户上次拖分隔条的结果**，
# 不是代码默认值。Swift 版实测过一次残留的 listWidth=577.46，于是中栏比默认宽出一大截
# —— 按默认值算出来的打码框全部错位，右侧栏「按 Agent 分布」的 Agent 名称被糊掉，
# 而它恰恰是这张图要展示的主体信息。
#
# Swift 版：   侧栏 230 / 中栏 241..641 / 右栏 647..1280
# Electron 版：cleanStore.ts 的 DEFAULT_COLUMN_WIDTHS = { sidebar: 208, list: 460 }
#              → 实测中栏白区在 219..678（208 + 11pt 分隔条）
# **两套默认值不一样**，所以坐标必须重测，绝不能平移。
#
# 拍截图前要确保用的是默认值：删掉 Electron userData 里的 Local Storage
# （~/Library/Application Support/ConversationClean/）。
EXPECTED_COLS = {"sidebar": (0, 219), "list": (219, 678), "detail": (678, 1280)}

# (说明, x0, y0, x1, y1) —— view 坐标（1280x820 基准）
#
# 只打码真正敏感的两类：会话标题（即首条 user prompt 原文）、项目路径。
# 刻意**保留**：Agent 名称、字节数、占比、相对时间 —— 这些正是这张图要展示的信息。
#
# 坐标全部由程序实测得出，不是目测：把打码后的图按 view 坐标逐行扫描墨迹，
# 找出每条文字带的上下沿（见 commit message 里记的扫描方法）。目测在这里栽过：
# 第一版把中栏 y0 定在 189，而实测第一行文字从 187 就开始 —— 顶部漏了 2pt，
# 放大后「本地 Agent 会话清理」的字头清晰可读。**差 2pt 就是数据泄漏。**
#
# 中栏（x 272..566，y 182..780）：
#   · 左界 272：白区从 219 起，行内 checkbox 占 219..272。
#   · 右界 566：行内右侧固定列（占比条 38 + gap 8 + 体积 52）从 566 起。
#     千万别往右扩到 600 —— 那会把占比条糊掉，而占比正是要展示的信息。
#   · 上界 182：实测首行文字顶在 187，留 5pt 余量。
#   · 下界 780：批量条（已选 N 项）在 ~790，往下就不是列表了。
#     上界要留这么宽是因为**行数不定** —— 10 条会话时文字会一直铺到 780。
#   · 行与行之间只有空白，占多高都不会误伤别的信息。
#
# 右栏为什么**逐行**打码而不是一个大框：
#   「按 Agent 分布」这一节的位置**取决于上面有几行** ——
#   Top3 时标题在 y≈260，Top4 被推到 ≈304，Top5 推到 ≈348。
#   所以「盖住全部 5 行」与「不糊掉分布区」对任何固定矩形都是互斥的。
#   （脚本注释里记过一次翻车：坐标错位把分布区的 Agent 名称糊掉了。）
#   改成按 Top5 的固定行距（实测 44pt）逐行打标题，5 行全盖、分布区永不受影响，
#   且不依赖这次截了几个会话。副标题（Agent 名 + 相对时间）保留 —— 不是敏感信息。
REGIONS = [
    ("中栏：会话标题 + 项目路径", 272, 182, 566, 780),
    ("右栏：占用大户 第1行标题", 728, 112, 1037, 128),
    ("右栏：占用大户 第2行标题", 728, 156, 1037, 172),
    ("右栏：占用大户 第3行标题", 728, 200, 1037, 216),
    ("右栏：占用大户 第4行标题", 728, 244, 1037, 260),
    ("右栏：占用大户 第5行标题", 728, 288, 1037, 304),
]



def check_column_widths(src: pathlib.Path, W: int, H: int) -> None:
    """打码前先验栏宽。对不上就抛错，而不是打出一张糊错位置的图。

    验的是**中栏白色区域的右边界**，这是最稳的栏宽指纹。
    两个反例说明为什么不能图省事：
      · 拿背景色当判据没用 —— 不同栏宽下图里侧栏/中栏颜色完全一样；
      · 拿分隔条当判据也脆 —— 它只有 1pt（retina 下 2px），定点采样极易错过，
        而且 Color→Pixel 的抗锯齿会让边缘色漂移。
    白色大块区域的边界则连续几十像素，采样误差不影响判定。
    """
    Y = round(600 * H / VIEW_H)

    def rgb_at_px(px_x: int) -> tuple[int, int, int]:
        out = subprocess.run(
            ["magick", str(src), "-crop", f"1x1+{px_x}+{Y}", "+repage",
             "-format", "%[pixel:p{0,0}]", "info:"],
            capture_output=True, text=True, check=True).stdout.strip()
        nums = out[out.index("(") + 1:out.index(")")].split(",")
        vals = [int(round(float(v))) for v in nums[:3]]
        # 万一又被判成灰度（`gray(255)` 只有 1 个分量），补齐成 RGB 再比。
        if len(vals) == 1:
            vals = vals * 3
        return tuple(vals)

    # 从 x=300pt 一路向右，找连续白区（#FFFFFF）的终点
    white_end = None
    for x_pt in range(300, 1100):
        r, g, b = rgb_at_px(round(x_pt * W / VIEW_W))
        if (r, g, b) == (255, 255, 255):
            white_end = x_pt
        elif white_end is not None and x_pt - white_end > 12:
            break
    expected = EXPECTED_COLS["list"][1]          # 678
    if white_end is None or abs(white_end - expected) > 4:
        raise SystemExit(
            f"栏宽与预期不符，拒绝打码：\n"
            f"  中栏右边界实测在 x≈{white_end}pt，预期 {expected}pt"
            f"（偏差 {None if white_end is None else white_end - expected:+d}pt）\n\n"
            f"原因：sidebarWidth / listWidth 存在 localStorage 里，"
            f"是上次拖分隔条的结果，不是代码默认值。\n"
            f"拍截图前先删掉 Electron userData 下的 Local Storage：\n"
            f"  rm -rf ~/Library/Application\\ Support/ConversationClean/Local\\ Storage")
    print(f"column widths OK: 中栏右边界 x={white_end}pt "
          f"（= 侧栏 208 + 分隔条 11 + 中栏 460 - 1 舍入）")


def main() -> None:
    raw, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    # 先归一到 sRGB 再干活。
    # macOS `screencapture` 出来的 PNG 带 ICC profile，ImageMagick 7 会照着它
    # 把图当成灰度，于是 `%[pixel:p{0,0}]` 吐 `gray(255)` 而不是 `srgb(255,255,255)`，
    # 下面的解析直接 unpack 失败。PIL 读同一张图是正常 RGB —— 是 IM 的解释问题，
    # 不是图坏了。所以在入口统一指定色彩空间，不依赖调用方记得加参数。
    tmpdir0 = pathlib.Path(tempfile.mkdtemp(prefix="ccnorm-"))
    src = tmpdir0 / "normalized.png"
    # `-define png:color-type=2` 强制按真 RGB 写出。`-colorspace sRGB` / `-strip`
    # 都不够：IM 7 会照着 macOS screencapture 内嵌的灰度 ICC profile 把整张图
    # 判成 grayscale，于是 `%[pixel:p{0,0}]` 吐 `gray(255)` 而不是
    # `srgb(255,255,255)`，下面的解析 unpack 失败。PIL 读同一张图是正常 RGB，
    # 所以是 IM 的解释问题、不是图坏了 —— 绕开它的 profile 解释即可。
    subprocess.run(
        ["magick", str(raw), "-colorspace", "sRGB", "-define", "png:color-type=2", str(src)],
        check=True)
    W, H = (int(v) for v in subprocess.run(
        ["magick", "identify", "-format", "%w %h", str(src)],
        capture_output=True, text=True, check=True).stdout.split())
    sx, sy = W / VIEW_W, H / VIEW_H
    check_column_widths(src, W, H)

    args = ["magick", str(src)]
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="ccmos-"))
    for i, (name, x0, y0, x1, y1) in enumerate(REGIONS):
        X, Y = round(x0 * sx), round(y0 * sy)
        w, h = round((x1 - x0) * sx), round((y1 - y0) * sy)
        if w < 2 or h < 2:
            print(f"skip (too small): {name}")
            continue
        # 每个区域必须用**独立**临时文件：先前所有区域写同一个路径，
        # 等 args 真正执行时那个文件只剩最后一个区域的内容，
        # 于是四张相同的图被贴到四个不同位置，糊出一片。
        tmp = tmpdir / f"mos{i}.png"
        # 把该区域压到 ~BLOCK 像素宽再放回去 = 经典马赛克，且不可逆
        subprocess.run(
            ["magick", str(src), "-crop", f"{w}x{h}+{X}+{Y}", "+repage",
             "-scale", f"{max(1, w // BLOCK)}x{max(1, h // BLOCK)}!",
             "-scale", f"{w}x{h}!", str(tmp)], check=True)
        args += ["(", str(tmp), ")", "-geometry", f"+{X}+{Y}", "-composite"]
        print(f"mosaic: {name}  {w}x{h}+{X}+{Y}")
    args.append(str(dst))
    subprocess.run(args, check=True)
    shutil.rmtree(tmpdir, ignore_errors=True)
    shutil.rmtree(tmpdir0, ignore_errors=True)
    print(f"-> {dst}")


if __name__ == "__main__":
    main()
