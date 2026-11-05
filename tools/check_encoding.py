# -*- coding: utf-8 -*-
"""编码护栏：改完脚本跑一遍，避免踩两个必踩的坑。

  .bat  必须 GBK + 纯 CRLF + 带 `chcp 936`
        按 UTF-8 存会被 cmd 以 936 代码页读坏：汉字三字节错位后，
        个别字节被当成 & | " ，命令行被截断，报出 'dressFamily' 不是内部命令
        这类看起来像代码 bug 的怪错。

  .ps1  必须 UTF-8 **带 BOM** + 纯 CRLF
        PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI(GBK) 解释，中文全乱码。

另外禁 `timeout /t`：stdin 被重定向时它立刻报错退出，统一用 ping 代替。
还检查 `if ... cmd & goto` 这种没加括号的写法 —— `&` 会脱离 if 无条件执行。

用法： python tools/check_encoding.py
返回： 0 全部通过；1 有不合格项
"""
from __future__ import print_function

import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAT_CHCP_EXEMPT = {"_env.bat"}


def check_bat(path, rel):
    raw = io.open(path, "rb").read()
    problems = []
    try:
        text = raw.decode("gbk")
    except UnicodeDecodeError as e:
        text = raw.decode("gbk", errors="replace")
        problems.append("非法 GBK 字节 @%d" % e.start)

    lone = raw.count(b"\n") - raw.count(b"\r\n")
    if lone:
        problems.append("裸 LF %d 处" % lone)
    if raw[:3] == b"\xef\xbb\xbf":
        problems.append("带 UTF-8 BOM")
    if os.path.basename(path) not in BAT_CHCP_EXEMPT and "chcp 936" not in text:
        problems.append("缺 chcp 936")
    if re.search(r"(?i)\btimeout\s+/t", text):
        problems.append("用了 timeout /t")
    # if 里带命令分隔符 & 但没加括号（排除 2>&1 这类重定向）
    for i, line in enumerate(text.split("\r\n"), 1):
        s = line.strip()
        if not s.lower().startswith("if "):
            continue
        nodir = re.sub(r"\d?>&\d?", "", s)   # 去掉 2>&1 / >&2 形式的重定向
        nodir = nodir.replace("&>", "")
        if "&" in nodir and "(" not in nodir:
            problems.append("第 %d 行 if 带 & 未加括号" % i)
    return problems


def check_ps1(path, rel):
    raw = io.open(path, "rb").read()
    problems = []
    if raw[:3] != b"\xef\xbb\xbf":
        problems.append("缺 UTF-8 BOM（PS 5.1 会按 GBK 读，中文乱码）")
    body = raw[3:] if raw[:3] == b"\xef\xbb\xbf" else raw
    try:
        body.decode("utf-8")
    except UnicodeDecodeError as e:
        problems.append("非法 UTF-8 字节 @%d" % e.start)
    lone = body.count(b"\n") - body.count(b"\r\n")
    if lone:
        problems.append("裸 LF %d 处" % lone)
    return problems


def main():
    targets = []
    targets += [(p, "bat") for p in glob.glob(os.path.join(ROOT, "*.bat"))]
    targets += [(p, "bat") for p in glob.glob(os.path.join(ROOT, "launcher", "*.bat"))]
    targets += [(p, "ps1") for p in glob.glob(os.path.join(ROOT, "tools", "*.ps1"))]
    targets.sort()

    if not targets:
        print("[失败] 没找到任何脚本")
        return 1

    bad = 0
    for path, kind in targets:
        rel = os.path.relpath(path, ROOT)
        problems = check_bat(path, rel) if kind == "bat" else check_ps1(path, rel)
        if problems:
            bad += 1
        print("%-6s %-34s %7d B  %s" % (
            "OK" if not problems else "FAIL",
            rel,
            os.path.getsize(path),
            "; ".join(problems),
        ))

    print("")
    if bad:
        print("[失败] %d 个文件不合格。.bat 用 GBK+CRLF 另存，.ps1 用 UTF-8 带 BOM 另存。" % bad)
        return 1
    print("[通过] %d 个脚本编码/换行全部合格。" % len(targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
