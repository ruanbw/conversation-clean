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

VIEW_W, VIEW_H = 1100, 688  # 缩略基准（本机原图 2880×1800）
BLOCK = 11                 # 马赛克块边长（最终像素）

# (说明, x0, y0, x1, y1) —— 缩略坐标
#
# 只打码真正敏感的三类：会话标题（即首条 user prompt 原文）、项目路径、会话 ID。
# 刻意**保留**：Agent 名称、字节数、占比、相对时间 —— 这些正是这张图要展示的信息，
# 全糊掉就看不出「哪款 Agent 占得多」。所以「按 Agent 分布」整块不动，
# 下面的统计表仍然列出每款 Agent 的名称与字节数。
#
# 区域要**给足**：早先按行开 18px 窄带，结果只切掉字形中间一条，
# 上下半截仍可读（“当前项目的 UI 样式…” 那行就是）。宁可多糊一点。
REGIONS = [
    # 右边界 396：再往右就咬到体积列的「45 MB」（相距 4pt，肉眼可见）。
    ("列表：会话标题 + 项目路径", 228, 128, 396, 670),
    # 右边界 486：分列条在 489，留 3pt。
    ("列表：会话 ID", 433, 128, 486, 670),
    # 只糊路径本身（y 288..304），下面的说明文字不是敏感信息，留着。
    ("侧栏：当前分类存储路径", 0, 288, 182, 304),
    # 右边界 926：占比条的圆角左端在 ~929，留 3pt。
    # 实测 848 时 row 3 的「…/Users/ruanbw/project…」尾巴整段露在外面；
    # 512 时更糟，整行几乎没糊到。
    ("详情栏：占用大户 5 行标题 + 副标题", 510, 64, 926, 240),
]


def main() -> None:
    src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    W, H = (int(v) for v in subprocess.run(
        ["magick", "identify", "-format", "%w %h", str(src)],
        capture_output=True, text=True, check=True).stdout.split())
    sx, sy = W / VIEW_W, H / VIEW_H

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
