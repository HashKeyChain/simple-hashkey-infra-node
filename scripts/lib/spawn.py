#!/usr/bin/env python3
"""把一个命令拉起成脱离当前会话的后台进程，并把它的 pid 打到 stdout。

为什么不用 `nohup cmd &`：nohup 只挡 SIGHUP。chain-start.sh 往往跑在终端、CI 步骤或
某种工具会话里，那类会话结束时会给**整个进程组**发信号（包括 SIGKILL），nohup 与
disown 都拦不住 —— 表现就是启动脚本一退出，op-geth / op-node / batcher / proposer
一起变成 DEAD。唯一可靠的做法是让子进程 setsid 进入自己的会话，从此与启动者的
进程组无关。

macOS 没有自带 setsid 命令，所以用 Python 的 os.setsid()。只用标准库。

用法：
    python3 spawn.py <日志文件> -- <命令> [参数...]

stdout 只输出一个 pid，便于调用方写 pid 文件；子进程的 stdout/stderr 追加进日志文件。
"""

import os
import sys


def main() -> int:
    argv = sys.argv[1:]
    if "--" not in argv:
        print("usage: spawn.py <log-file> -- <command> [args...]", file=sys.stderr)
        return 2
    sep = argv.index("--")
    if sep != 1:
        print("usage: spawn.py <log-file> -- <command> [args...]", file=sys.stderr)
        return 2
    log_path = argv[0]
    cmd = argv[sep + 1:]
    if not cmd:
        print("no command given to execute", file=sys.stderr)
        return 2

    pid = os.fork()
    if pid != 0:
        # 父进程只负责报告 pid。子进程 setsid 后被 init 收养，与本进程再无关系。
        print(pid)
        return 0

    os.setsid()
    fd_log = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    fd_null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(fd_null, 0)
    os.dup2(fd_log, 1)
    os.dup2(fd_log, 2)
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        os.write(2, f"spawn failed: {e}\n".encode())
        os._exit(127)
    return 0


if __name__ == "__main__":
    sys.exit(main())
