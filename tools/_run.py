#!/usr/bin/env python3
"""_run.py — bounded process execution for tools/verify.sh. Not a user command.

A POSIX shell cannot portably (a) put a child in its own process group, (b) kill
that whole group, or (c) bound a command by wall clock without `timeout(1)`,
which stock macOS does not ship. `tools/verify.sh` therefore delegates those
three things here. Nothing else in the kit depends on this file: the gates,
`tools/auto.sh` and `tools/handoff.sh` remain shell + git only.

Subcommands (all take --cmd as ONE shell string, run through `sh -c`):

  exec   --cmd C --log F --timeout S      run C to completion, stdin </dev/null,
                                          output appended to F. Exit = the
                                          command's own status, or 124 on
                                          timeout (the whole process group is
                                          terminated, then killed). INT/TERM
                                          reaching this helper take that same
                                          group down at once and exit 128+signal,
                                          so an interrupted verification stops
                                          the command it is running instead of
                                          waiting for it.
  launch --cmd C --log F --pidfile P      start C detached in its OWN process
                                          group, record that group id in P, and
                                          return at once. Exit 0 when the group
                                          is alive after the handshake wait.
  alive  --pidfile P                      exit 0 while any member of the
                                          recorded group is alive.
  stop   --pidfile P --timeout S          terminate the whole recorded group
                                          (TERM, then KILL). Exit 0 only when
                                          nothing of it is left; 1 says so
                                          explicitly instead of hanging.

Exit 2 is a usage or environment error of this helper itself.
"""
import argparse
import os
import signal
import subprocess
import sys
import time

TIMEOUT_RC = 124
WINDOWS = os.name == "nt"


def _open_log(path, append=True):
    if not path:
        return subprocess.DEVNULL, None
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    fh = open(path, "ab" if append else "wb")
    return fh, fh


def _spawn(cmd, log, new_group=True):
    out, fh = _open_log(log)
    kwargs = {"stdin": subprocess.DEVNULL, "stdout": out, "stderr": subprocess.STDOUT}
    if new_group:
        if WINDOWS:
            kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            kwargs["start_new_session"] = True
    try:
        p = subprocess.Popen(["sh", "-c", cmd], **kwargs)
    finally:
        if fh is not None:
            fh.close()
    return p


def _kill_tree(pid, sig):
    """Signal the whole process group of pid. True when the signal was sent."""
    if WINDOWS:
        rc = subprocess.call(
            ["taskkill", "/T", "/F", "/PID", str(pid)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return rc == 0
    try:
        os.killpg(os.getpgid(pid), sig)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        try:
            os.kill(pid, sig)
            return True
        except OSError:
            return False


def _group_alive(pid):
    if WINDOWS:
        rc = subprocess.call(
            ["tasklist", "/FI", "PID eq %d" % pid],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return rc == 0
    try:
        os.killpg(os.getpgid(pid), 0)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False


def _stop(p):
    """Take the child's whole group down: TERM, a bounded wait, then KILL."""
    _kill_tree(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _kill_tree(p.pid, signal.SIGKILL)
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def cmd_exec(a):
    if a.timeout <= 0:
        print("_run.py: --timeout must be a positive number of seconds", file=sys.stderr)
        return 2
    p = _spawn(a.cmd, a.log)
    # The command runs in its OWN group, so a signal sent to this helper (or to
    # the shell's foreground group) never reaches it. Forward it explicitly:
    # an interrupted run must stop the command it is running, not outlive it.
    # Windows has no process groups here; taskkill inside _kill_tree does the
    # same job, and CREATE_NEW_PROCESS_GROUP likewise isolates the child.
    caught = {}

    def _forward(signum, _frame):
        caught.setdefault("signal", signum)
        _stop(p)

    installed = []
    for s in (signal.SIGINT, getattr(signal, "SIGTERM", None), getattr(signal, "SIGHUP", None)):
        if s is None:
            continue
        try:
            installed.append((s, signal.signal(s, _forward)))
        except (ValueError, OSError, RuntimeError):
            pass
    try:
        try:
            rc = p.wait(timeout=a.timeout)
        except subprocess.TimeoutExpired:
            rc = None
        if caught.get("signal"):
            if a.log:
                with open(a.log, "a") as fh:
                    fh.write("\n[sdlc-kit] interrupted (signal %d) — process group terminated\n"
                             % caught["signal"])
            return 128 + caught["signal"]
        if rc is not None:
            return rc
    finally:
        for s, previous in installed:
            try:
                signal.signal(s, previous)
            except (ValueError, OSError, RuntimeError):
                pass
    # Timed out: take the whole group down, gently first.
    _stop(p)
    if a.log:
        with open(a.log, "a") as fh:
            fh.write("\n[sdlc-kit] timed out after %gs — process group terminated\n" % a.timeout)
    return TIMEOUT_RC


def cmd_launch(a):
    p = _spawn(a.cmd, a.log)
    with open(a.pidfile, "w") as fh:
        fh.write("%d\n" % p.pid)
    # Handshake: a launch command that dies immediately (a syntax error, a port
    # already in use) must be reported as `failed` here, not discovered later as
    # "something on that port answered the doctor".
    deadline = time.time() + max(a.settle, 0.0)
    while True:
        rc = p.poll()
        if rc is not None:
            print("launch exited immediately with status %d" % rc, file=sys.stderr)
            return 1
        if time.time() >= deadline:
            break
        time.sleep(0.1)
    return 0 if _group_alive(p.pid) else 1


def _read_pid(path):
    try:
        with open(path) as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return None


def cmd_alive(a):
    pid = _read_pid(a.pidfile)
    if pid is None:
        return 2
    return 0 if _group_alive(pid) else 1


def cmd_stop(a):
    pid = _read_pid(a.pidfile)
    if pid is None:
        return 2
    if not _group_alive(pid):
        return 0
    _kill_tree(pid, signal.SIGTERM)
    deadline = time.time() + max(a.timeout, 1)
    while time.time() < deadline:
        if not _group_alive(pid):
            return 0
        time.sleep(0.2)
    _kill_tree(pid, signal.SIGKILL)
    deadline = time.time() + 5
    while time.time() < deadline:
        if not _group_alive(pid):
            return 0
        time.sleep(0.2)
    print("process group %d survived TERM and KILL" % pid, file=sys.stderr)
    return 1


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    sub = ap.add_subparsers(dest="sub")
    e = sub.add_parser("exec"); e.add_argument("--cmd", required=True)
    e.add_argument("--log", default=""); e.add_argument("--timeout", type=float, required=True)
    e.set_defaults(fn=cmd_exec)
    l = sub.add_parser("launch"); l.add_argument("--cmd", required=True)
    l.add_argument("--log", default=""); l.add_argument("--pidfile", required=True)
    l.add_argument("--settle", type=float, default=0.5)
    l.set_defaults(fn=cmd_launch)
    v = sub.add_parser("alive"); v.add_argument("--pidfile", required=True)
    v.set_defaults(fn=cmd_alive)
    s = sub.add_parser("stop"); s.add_argument("--pidfile", required=True)
    s.add_argument("--timeout", type=float, default=15)
    s.set_defaults(fn=cmd_stop)
    a = ap.parse_args(argv)
    if not getattr(a, "fn", None):
        ap.print_usage(sys.stderr)
        return 2
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
