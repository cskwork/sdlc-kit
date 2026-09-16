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
                                          recorded group is alive. The probe is
                                          non-destructive on every platform: it
                                          never signals what it is asking about.
  stop   --pidfile P --timeout S          terminate the whole recorded group
                                          (TERM, then KILL). Exit 0 only when
                                          nothing of it is left; 1 says so
                                          explicitly instead of hanging.

Exit 2 is a usage or environment error of this helper itself.

Windows (Git Bash is a first-class target) has neither process groups nor
signals in the POSIX sense, so the same three jobs are done with the native
equivalents: OpenProcess/WaitForSingleObject for liveness, `taskkill /T /F` for
the tree, and — for `exec` only — a job object that dies with this helper, so a
command it is waiting on is not orphaned (still holding its log file open) when
MSYS `kill` terminates this process outright. A LAUNCHED runtime is deliberately
not in that job: it has to outlive the helper that started it.

Two limits of that containment, stated rather than assumed:
  * It is not guaranteed to exist. If the job object cannot be created,
    configured or assigned, this helper says so by name on stderr and in the
    run's `--log` and keeps going WITHOUT claiming the containment. It never
    reports it as working when it is not; an interrupted run still exits
    non-zero and still writes no receipt.
  * The child is assigned to the job just AFTER `subprocess.Popen` returns, so a
    grandchild created inside that window is outside the job. The window cannot
    be closed from here (`CREATE_SUSPENDED` is not usable: CPython closes the
    child's thread handle before returning, leaving nothing to resume), and it
    is small but not zero.
"""
import argparse
import csv
import os
import signal
import subprocess
import sys
import time

TIMEOUT_RC = 124
WINDOWS = os.name == "nt"
# Windows Python has no SIGKILL. _kill_tree ignores the signal there (taskkill
# /F is the only stop Windows offers), but the name still has to resolve:
# `signal.SIGKILL` used to raise AttributeError inside the escalation path, so
# every Windows stop that needed a second attempt died with a traceback and the
# run was reported as "could not stop what it started".
SIGKILL = getattr(signal, "SIGKILL", getattr(signal, "SIGTERM", 15))

# --- Windows process primitives ----------------------------------------------
# os.kill(pid, 0) is NOT a liveness probe on Windows: the documentation is
# explicit that any signal other than CTRL_C_EVENT/CTRL_BREAK_EVENT is
# implemented with TerminateProcess, so probing would kill the process.
# `tasklist` is not one either — it exits 0 whether or not the filter matched,
# which made every dead process read as alive. OpenProcess +
# WaitForSingleObject/GetExitCodeProcess is the documented non-destructive
# answer, so that is what this uses.
_WIN = None
if WINDOWS:
    try:
        import ctypes
        from ctypes import wintypes

        SYNCHRONIZE = 0x00100000
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        WAIT_OBJECT_0 = 0
        ERROR_ACCESS_DENIED = 5
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
        JobObjectExtendedLimitInformation = 9

        _WIN = ctypes.WinDLL("kernel32", use_last_error=True)
        # Every prototype is declared: a HANDLE is 64-bit in a 64-bit process and
        # ctypes' default `int` return would truncate it into an invalid handle.
        _WIN.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        _WIN.OpenProcess.restype = wintypes.HANDLE
        _WIN.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        _WIN.WaitForSingleObject.restype = wintypes.DWORD
        _WIN.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        _WIN.GetExitCodeProcess.restype = wintypes.BOOL
        _WIN.CloseHandle.argtypes = (wintypes.HANDLE,)
        _WIN.CloseHandle.restype = wintypes.BOOL
        _WIN.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
        _WIN.CreateJobObjectW.restype = wintypes.HANDLE
        _WIN.SetInformationJobObject.argtypes = (
            wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
        _WIN.SetInformationJobObject.restype = wintypes.BOOL
        _WIN.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        _WIN.AssignProcessToJobObject.restype = wintypes.BOOL

        class _IO_COUNTERS(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class _JOB_BASIC_LIMITS(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", wintypes.LARGE_INTEGER),
                        ("PerJobUserTimeLimit", wintypes.LARGE_INTEGER),
                        ("LimitFlags", wintypes.DWORD),
                        ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t),
                        ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t),
                        ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class _JOB_EXTENDED_LIMITS(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", _JOB_BASIC_LIMITS),
                        ("IoInfo", _IO_COUNTERS),
                        ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t),
                        ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]
    except Exception:  # no ctypes: fall back to parsing tasklist output
        _WIN = None

# Job handles are kept here for the lifetime of the process on purpose: closing
# one is what tears the child tree down, so it must not be garbage collected.
_JOBS = []


def _win_alive(pid):
    """Non-destructive: is that native Windows pid still running?"""
    if pid <= 0:
        return False
    if _WIN is None:
        # tasklist's EXIT STATUS says nothing; only its output does.
        try:
            out = subprocess.run(
                ["tasklist", "/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=30).stdout.decode("utf-8", "replace")
        except Exception:
            return True
        # CSV so the PID is a FIELD, not a substring of the line. The memory
        # column is printed as e.g. `5,432 K`, so `str(pid) in out` reported
        # pid 5 (and 432, and 43) as alive whenever any such process existed.
        for row in csv.reader(out.splitlines()):
            if len(row) > 1 and row[1].strip() == str(pid):
                return True
        return False
    h = _WIN.OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not h:
        # The process is gone, unless it is merely out of reach for this account.
        return ctypes.get_last_error() == ERROR_ACCESS_DENIED
    try:
        if _WIN.WaitForSingleObject(h, 0) == WAIT_OBJECT_0:
            return False  # a process handle is signalled exactly when it exits
        code = wintypes.DWORD()
        if _WIN.GetExitCodeProcess(h, ctypes.byref(code)):
            return code.value == STILL_ACTIVE
        return True
    finally:
        _WIN.CloseHandle(h)


def _report(message, log=None):
    """Say it where both the operator and the run's own log will see it."""
    line = "[sdlc-kit] " + message
    print(line, file=sys.stderr, flush=True)
    if log:
        try:
            with open(log, "ab") as fh:
                fh.write((line + "\n").encode("utf-8", "replace"))
        except OSError:
            pass


def _win_bind_tree(proc):
    """Tie the child's whole tree to this helper's own lifetime.

    MSYS `kill` reaches a native python3 through TerminateProcess, so on the
    interrupted path this helper's signal handler never runs and the check it
    started used to be orphaned — still holding its log file open, which is why
    the fixture teardown hit "Device or resource busy". A job object with
    KILL_ON_JOB_CLOSE is the teardown Windows honours even then: when this
    process dies, by any means, the OS closes the handle and the job goes with
    it. Only the process this helper started is ever in that job.

    Returns None when the tree is bound, otherwise a short reason naming the
    Win32 call that refused and its error code. The caller REPORTS that reason:
    returning a bare False made the one interesting failure — the containment
    this helper's docstring promises is not there — completely silent, so the
    only symptom was the original "Device or resource busy" with nothing to
    trace it to.
    """
    if _WIN is None:
        return "kernel32 not reachable through ctypes"
    try:
        job = _WIN.CreateJobObjectW(None, None)
        if not job:
            return "CreateJobObjectW, Win32 error %d" % ctypes.get_last_error()
        info = _JOB_EXTENDED_LIMITS()
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not _WIN.SetInformationJobObject(
                job, JobObjectExtendedLimitInformation,
                ctypes.byref(info), ctypes.sizeof(info)):
            # read before CloseHandle: closing a handle overwrites the last error
            reason = "SetInformationJobObject, Win32 error %d" % ctypes.get_last_error()
            _WIN.CloseHandle(job)
            return reason
        if not _WIN.AssignProcessToJobObject(job, int(proc._handle)):
            reason = "AssignProcessToJobObject, Win32 error %d" % ctypes.get_last_error()
            _WIN.CloseHandle(job)
            return reason
        _JOBS.append(job)
        return None
    except Exception as exc:
        return "%s: %s" % (type(exc).__name__, exc)


def _open_log(path, append=True):
    if not path:
        return subprocess.DEVNULL, None
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    fh = open(path, "ab" if append else "wb")
    return fh, fh


def _spawn(cmd, log, new_group=True, bind_tree=False):
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
        # This helper keeps no handle on the log: the child writes it, and only
        # the child's death releases it.
        if fh is not None:
            fh.close()
    # bind_tree is for the children this helper WAITS for (exec). A launched
    # runtime must outlive this process, so it is never put in the job.
    if bind_tree and WINDOWS:
        reason = _win_bind_tree(p)
        if reason is not None:
            _report("windows: process tree NOT bound to this helper (%s). If this run is "
                    "interrupted, the command it is waiting on may keep running and keep "
                    "its log file open." % reason, log)
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
    # The pid is always the NATIVE pid of the process this helper started (the
    # one subprocess reports and the one taskkill understands). It is never an
    # MSYS/Git-Bash pid: those two number spaces do not correspond, and only
    # this helper ever writes or reads the pidfile.
    if WINDOWS:
        return _win_alive(pid)
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
        _kill_tree(p.pid, SIGKILL)
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def cmd_exec(a):
    if a.timeout <= 0:
        print("_run.py: --timeout must be a positive number of seconds", file=sys.stderr)
        return 2
    p = _spawn(a.cmd, a.log, bind_tree=True)
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
    _kill_tree(pid, SIGKILL)
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
