#!/usr/bin/env python3
"""Drive the agent through a real TTY, answering the approval prompt with keystrokes."""
import os, pty, shutil, sys, time, select, tempfile
from pathlib import Path


def run(answers, config_path, workspace=None, timeout=90):
    repo_root = Path(__file__).resolve().parent.parent
    pwsh = shutil.which("pwsh") or os.path.expanduser("~/.local/pwsh/pwsh")
    ws = workspace or tempfile.mkdtemp(prefix="tty-agent-ws-")
    argv = [
        pwsh, "-NoLogo", "-NoProfile", "-File",
        str(repo_root / "Agent.ps1"), "-NoColor",
        "-Workspace", str(ws),
        "-ConfigPath", str(config_path), "interactive test"
    ]
    env = dict(
        os.environ,
        TERM="dumb",
        MOCK_KEY="x",
        MOCK_SCRIPT=str(repo_root / "tests" / "script_tty.json")
    )
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    out = b""
    sent = 0
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.4)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            # Answer CSI 6n cursor position queries if PowerShell sends them
            if b"\x1b[6n" in chunk:
                os.write(fd, b"\x1b[1;1R")
            if (b"?" in chunk or b"feedback >" in chunk) and sent < len(answers):
                time.sleep(0.15)
                os.write(fd, answers[sent].encode())
                sent += 1
        else:
            try:
                wpid, _ = os.waitpid(pid, os.WNOHANG)
                if wpid:
                    break
            except ChildProcessError:
                break
    try:
        os.waitpid(pid, 0)
    except Exception:
        pass
    if workspace is None:
        shutil.rmtree(ws, ignore_errors=True)
    return out.decode(errors="replace")


if __name__ == "__main__":
    cfg = sys.argv[1] if len(sys.argv) > 1 else "/tmp/testcfg.json"
    res = run(["y", "n", "f", "please use a record instead\n"], cfg)
    print(res)
