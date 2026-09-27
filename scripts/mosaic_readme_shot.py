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

# 三条分隔条在 VIEW_W 坐标系里的预期 x。用来在打码前校验截图栏宽，
# 不一致就直接报错停下。
#
# 🔴 这里踩过坑：三栏宽度存在 @AppStorage（sidebarWidth / listWidth）里，
# 是**用户上次拖分隔条的结果**，不是代码默认值。实测过一次残留的
# listWidth=577.46，于是中栏 578pt / 右栏 455pt，比默认宽出一大截 ——
# 按默认值算出来的打码框全部错位，右侧栏「按 Agent 分布」的 Agent 名称
# 被糊掉，而它恰恰是这张图要展示的主体信息。
# 所以：拍截图前必须先 `defaults delete <bundle> sidebarWidth listWidth`。
EXPECTED_COLS = {"sidebar": (0, 230), "list": (241, 641), "detail": (647, 1280)}

# (说明, x0, y0, x1, y1) —— 缩略坐标
#
# 只打码真正敏感的三类：会话标题（即首条 user prompt 原文）、项目路径。
# 刻意**保留**：Agent 名称、字节数、占比、相对时间 —— 这些正是这张图要展示的信息，
# 全糊掉就看不出「哪款 Agent 占得多」。所以「按 Agent 分布」整块不动，
# 下面的统计表仍然列出每款 Agent 的名称与字节数。
#
# 坐标全部从新布局的控件宽度与实测绘图得出，不是目测：
#   中栏 241..641pt，行 padding .leading 10 / .horizontal 16 → 内容 251..625pt；
#     右侧固定列 ShareBar 38 + gap 8 + 体积 52 = 98pt，占到 527..625
#     → .tcol 右边界 519pt。取 258..522（两边各留 3pt），
#     千万别往右扩到 540 —— 那会连占比条一起糊掉，占比正是要展示的信息。
#     y：列表行从 154pt 开始（实测第一行文字 y 154..164），行高 32pt，末行到 ~800pt。
#   侧栏存储路径：实测「~/.pi」文字在 y 383..392pt。上下两行分别是
#     「存储路径」小标题（y≈371）和「清理时同步删除…」策略说明（y 402..410），
#     后者不是敏感信息，所以只糊 374..400 这一行。
#   右栏 652..1280pt，det-scroll padding 24 + 卡片 padding 14 → 内容 690..1242pt；
#     固定列 占比条 76 + gap 12 + 百分比 34 + gap 12 + 大小 58 = 204pt
#     → .nm 右边界 1038pt。取 688..1040。
#     y：卡片首行文字 y 154..165，5 行止于 y≈491（实测最后一段 475..491），
#     取 148..505。再往下 y 515 起是「按 Agent 分布」的 4 行 Agent 名称 ——
#     那是这张图要展示的主体信息，**必须留在外面**。
REGIONS = [
    # 中栏 241..641pt，行 padding .leading 10 / .horizontal 16 → 内容 251..624pt；
    #   右侧固定列 ShareBar 38 + gap 8 + 体积 52 = 98pt 占到 526..624
    #   → .tcol 右边界 518pt。取 255..521。千万别往右扩到 540：
    #   那会连占比条一起糊掉，而占比正是这张图要展示的信息。
    #   y：第一行文字 154..164pt，行高 32pt，末行到 ~800pt。
    ("列表：会话标题 + 项目路径", 255, 148, 521, 805),
    # 会话 ID 列在本次改造中已删除（它占 62pt 却用 tertiary 色几乎不可见），
    # 所以不再需要为它保留打码区。
    # 侧栏：实测「~/.pi」文字在 y 383..392pt。上下分别是「存储路径」小标题
    #   （y≈371）和「清理时同步删除…」策略说明（y 402..410），
    #   后者不是敏感信息，所以只糊 374..400 这一行。
    ("侧栏：当前分类存储路径", 12, 374, 228, 400),
    # 右栏 647..1280pt，det-scroll padding 24 + 卡片 padding 14 → 内容 671..1255 → 卡内 685..1241pt；
    #   固定列 76 + 12 + 34 + 12 + 58 = 204pt → .nm 右边界 1037pt。取 683..1041。
    #   y：卡首行文字 154..165pt，5 行止于 ~491pt，取 148..505。
    #   再往下 y 515 起是「按 Agent 分布」的 4 行 Agent 名称 ——
    #   那是这张图要展示的主体信息，**必须留在外面**。
    ("详情栏：占用大户 5 行标题 + 副标题", 683, 148, 1041, 505),
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
        return tuple(int(round(float(v))) for v in nums[:3])

    # 从 x=300pt 一路向右，找连续白区（#FFFFFF）的终点
    white_end = None
    for x_pt in range(300, 1100):
        r, g, b = rgb_at_px(round(x_pt * W / VIEW_W))
        if (r, g, b) == (255, 255, 255):
            white_end = x_pt
        elif white_end is not None and x_pt - white_end > 12:
            break
    expected = EXPECTED_COLS["list"][1]          # 641
    if white_end is None or abs(white_end - expected) > 4:
        raise SystemExit(
            f"栏宽与预期不符，拒绝打码：\n"
            f"  中栏右边界实测在 x≈{white_end}pt，预期 {expected}pt"
            f"（偏差 {None if white_end is None else white_end - expected:+d}pt）\n\n"
            f"原因：sidebarWidth / listWidth 存在 @AppStorage 里，"
            f"是上次拖分隔条的结果，不是代码默认值。\n"
            f"拍截图前先执行：\n"
            f"  defaults delete com.ruanbw.ConversationClean sidebarWidth\n"
            f"  defaults delete com.ruanbw.ConversationClean listWidth")
    print(f"column widths OK: 中栏右边界 x={white_end}pt "
          f"（= 侧栏 230 + 中栏 400 + 两条分隔条 11pt）")


def main() -> None:
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
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
    print(f"-> {dst}")


if __name__ == "__main__":
    main()
