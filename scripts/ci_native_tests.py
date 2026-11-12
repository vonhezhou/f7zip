#!/usr/bin/env python3
"""运行原生回归，阻塞时同时输出 Python 和 macOS 原生堆栈。"""
import faulthandler
import os
import platform
import subprocess
import threading
import unittest


def diagnose_timeout():
    faulthandler.dump_traceback()
    if platform.system() == 'Darwin':
        try:
            sample = subprocess.run(['sample', str(os.getpid()), '1', '1'],
                                    capture_output=True, text=True, timeout=15)
            log = sample.stdout or sample.stderr
            for offset in range(0, len(log), 3500):
                message = log[offset:offset + 3500].replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
                print(f'::error::{message}', flush=True)
        except subprocess.TimeoutExpired:
            print('::error::原生堆栈采样超时', flush=True)
    os._exit(1)


def main():
    watchdog = threading.Timer(300, diagnose_timeout)
    watchdog.daemon = True
    watchdog.start()
    try:
        suite = unittest.defaultTestLoader.discover('test', pattern='*_test.py')
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    finally:
        watchdog.cancel()


if __name__ == '__main__':
    raise SystemExit(main())
