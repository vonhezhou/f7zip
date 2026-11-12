#!/usr/bin/env python3
"""把失败日志尾部写入 Actions 检查注释，便于定位各平台构建错误。"""
from collections import deque
import shutil
import subprocess
import sys


def main():
    command = sys.argv[1:]
    if not command:
        raise SystemExit('请提供需要执行的命令')
    command[0] = shutil.which(command[0]) or command[0]
    tail = deque(maxlen=60)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding='utf-8', errors='replace')
    for line in process.stdout:
        print(line, end='', flush=True)
        tail.append(line.rstrip())
    status = process.wait()
    if status:
        # GitHub 单条注释最多保留 4096 字符，长链接命令不能挤掉真正的错误。
        lines = [line if len(line) <= 600 else line[:450] + ' … ' + line[-100:] for line in tail]
        log = '\n'.join(lines)
        for offset in range(0, len(log), 3500):
            message = log[offset:offset + 3500].replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
            print(f'::error::{message}', flush=True)
    return status


if __name__ == '__main__':
    sys.exit(main())
