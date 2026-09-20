#!/usr/bin/env python3
"""Run ONE command with SeBackupPrivilege and SeRestorePrivilege REMOVED.

TEST-ONLY helper for gates/knowledge-test.sh (C10a/C10). Nothing the kit ships
at runtime uses it, and it is never imported.

Why it exists
-------------
The C10 fixture needs a directory the current user really cannot write into.
On NTFS that is an explicit deny ACE, and gates/knowledge-test.sh sets one with
icacls. On the GitHub windows-latest runner that was not enough: the CI account
(runneradmin, RID 500) holds SeBackupPrivilege and SeRestorePrivilege ENABLED,
and both a native CreateDirectory and an MSYS mkdir succeeded against a
directory carrying `runneradmin:(DENY)(W)` (evidence:
.sdlc/work/260920-external-knowledge-area/scratch/ci-windows-diagnostics.log,
run 35517903326). A privileged token is a property of the CI fixture, not proof
that the product skips Windows permission errors.

So the write probe and the real init.sh run in a child whose token no longer
carries those two privileges.

Why SE_PRIVILEGE_REMOVED and not "disable"
------------------------------------------
AdjustTokenPrivileges with SE_PRIVILEGE_REMOVED (0x4) deletes the privilege
from the token instead of clearing its enabled bit; the docs call that
irreversible, so the MSYS runtime in the child cannot enable it again at
startup the way it can with a merely disabled privilege. CreateProcess gives
the child a copy of this process's primary token, so the removal is inherited.
No impersonation, no restricted-token construction, and no machine or account
state is touched: the edit applies to THIS helper process only, and dies with
it. The shell that launched the helper keeps its own privileges, which is what
lets the test restore the fixture ACL afterwards.

  AdjustTokenPrivileges / SE_PRIVILEGE_REMOVED:
    https://learn.microsoft.com/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges
  TOKEN_PRIVILEGES:
    https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-token_privileges
  Privilege constants (SE_BACKUP_NAME, SE_RESTORE_NAME):
    https://learn.microsoft.com/windows/win32/secauthz/privilege-constants

Usage
-----
  win-restricted-run.py --report            print the privileges before and
                                            after the removal, run nothing
  win-restricted-run.py -- <prog> [args...] remove, prove removed, then run

Exit status
-----------
  <the command's own exit status>  normal path; output is the command's own
  90  not Windows, or unusable arguments
  91  the token could not be opened or adjusted
  92  a privilege is STILL on the token after the removal (never run anything)
  93  the command could not be started
Codes 90-93 mean "this proves nothing", not "the command failed": the caller
reports NOT VERIFIED on them.
"""

import os
import subprocess
import sys

TARGETS = ("SeBackupPrivilege", "SeRestorePrivilege")

E_USAGE, E_TOKEN, E_STILL_THERE, E_SPAWN = 90, 91, 92, 93

TOKEN_ADJUST_PRIVILEGES = 0x0020
TOKEN_QUERY = 0x0008
SE_PRIVILEGE_ENABLED = 0x00000002
SE_PRIVILEGE_REMOVED = 0x00000004
TokenPrivileges = 3
ERROR_INSUFFICIENT_BUFFER = 122


def die(code, msg):
    sys.stderr.write("win-restricted-run: %s\n" % msg)
    sys.exit(code)


if sys.platform != "win32":
    die(E_USAGE, "this helper only means anything on native Windows Python "
                 "(sys.platform=%r)" % sys.platform)

import ctypes  # noqa: E402  (only reachable on Windows)
from ctypes import wintypes  # noqa: E402

advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)


class LUID(ctypes.Structure):
    _fields_ = [("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG)]


class LUID_AND_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("Luid", LUID), ("Attributes", wintypes.DWORD)]


# Prototypes are declared, not left to ctypes' defaults: GetCurrentProcess
# returns the pseudo-handle (HANDLE)-1, and a default c_int return would be
# truncated on 64-bit before OpenProcessToken ever sees it.
kernel32.GetCurrentProcess.restype = wintypes.HANDLE
kernel32.GetCurrentProcess.argtypes = []
advapi32.OpenProcessToken.restype = wintypes.BOOL
advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD,
                                      ctypes.POINTER(wintypes.HANDLE)]
advapi32.LookupPrivilegeValueW.restype = wintypes.BOOL
advapi32.LookupPrivilegeNameW.restype = wintypes.BOOL
advapi32.GetTokenInformation.restype = wintypes.BOOL
advapi32.AdjustTokenPrivileges.restype = wintypes.BOOL


def token_privileges_struct(count):
    class TOKEN_PRIVILEGES(ctypes.Structure):
        _fields_ = [("PrivilegeCount", wintypes.DWORD),
                    ("Privileges", LUID_AND_ATTRIBUTES * count)]
    return TOKEN_PRIVILEGES


def win_error(what):
    err = ctypes.get_last_error()
    return "%s failed (GetLastError=%d: %s)" % (
        what, err, ctypes.FormatError(err).strip())


def open_own_token():
    handle = wintypes.HANDLE()
    ok = advapi32.OpenProcessToken(
        kernel32.GetCurrentProcess(),
        TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY,
        ctypes.byref(handle))
    if not ok:
        die(E_TOKEN, win_error("OpenProcessToken"))
    return handle


def lookup_luid(name):
    luid = LUID()
    if not advapi32.LookupPrivilegeValueW(None, name, ctypes.byref(luid)):
        die(E_TOKEN, win_error("LookupPrivilegeValueW(%s)" % name))
    return luid


def privilege_name(luid):
    """The privilege's real name, or death. Never a placeholder: the absence
    proof is keyed on these names, so an unnamed entry would silently read as
    'the target is gone' when the lookup merely failed."""
    size = wintypes.DWORD(0)
    ctypes.set_last_error(0)
    ok = advapi32.LookupPrivilegeNameW(None, ctypes.byref(luid), None,
                                       ctypes.byref(size))
    # The sizing call MUST fail with ERROR_INSUFFICIENT_BUFFER and MUST fill in
    # a length; anything else (success, or another error) means we cannot trust
    # the name we are about to key the map on.
    if ok or ctypes.get_last_error() != ERROR_INSUFFICIENT_BUFFER \
            or not size.value:
        die(E_TOKEN, win_error("LookupPrivilegeNameW sizing"))
    buf = ctypes.create_unicode_buffer(size.value + 1)
    size = wintypes.DWORD(len(buf))
    ctypes.set_last_error(0)
    if not advapi32.LookupPrivilegeNameW(None, ctypes.byref(luid), buf,
                                         ctypes.byref(size)):
        die(E_TOKEN, win_error("LookupPrivilegeNameW"))
    return buf.value


def current_privileges(token):
    """{name: 'Enabled'|'Disabled'} for every privilege still on the token."""
    size = wintypes.DWORD(0)
    advapi32.GetTokenInformation(token, TokenPrivileges, None, 0,
                                 ctypes.byref(size))
    # The sizing call is EXPECTED to fail with ERROR_INSUFFICIENT_BUFFER; only
    # a size it never filled in is a real failure. The second call decides.
    if not size.value:
        die(E_TOKEN, win_error("GetTokenInformation(TokenPrivileges) sizing"))
    buf = ctypes.create_string_buffer(size.value)
    if not advapi32.GetTokenInformation(token, TokenPrivileges, buf,
                                        size, ctypes.byref(size)):
        die(E_TOKEN, win_error("GetTokenInformation(TokenPrivileges)"))
    count = ctypes.cast(buf, ctypes.POINTER(wintypes.DWORD))[0]
    found = {}
    if count:
        privs = ctypes.cast(
            buf, ctypes.POINTER(token_privileges_struct(count))
        )[0].Privileges
        for i in range(count):
            state = "Enabled" if privs[i].Attributes & SE_PRIVILEGE_ENABLED \
                else "Disabled"
            found[privilege_name(privs[i].Luid)] = state
    return found


def remove_targets(token):
    tp = token_privileges_struct(len(TARGETS))()
    tp.PrivilegeCount = len(TARGETS)
    for i, name in enumerate(TARGETS):
        tp.Privileges[i].Luid = lookup_luid(name)
        tp.Privileges[i].Attributes = SE_PRIVILEGE_REMOVED
    ctypes.set_last_error(0)
    ok = advapi32.AdjustTokenPrivileges(token, False, ctypes.byref(tp), 0,
                                        None, None)
    err = ctypes.get_last_error()
    # A privilege the token never had is not an error here: ERROR_NOT_ALL_
    # ASSIGNED (1300) with a successful call still leaves it absent, which is
    # the state being asked for. The check below is what decides either way.
    if not ok and err not in (0, 1300):
        die(E_TOKEN, win_error("AdjustTokenPrivileges"))


def describe(state):
    return " ".join("%s=%s" % (n, state.get(n, "<absent>")) for n in TARGETS)


def main(argv):
    token = open_own_token()
    before = current_privileges(token)

    if argv[:1] == ["--report"]:
        if len(argv) != 1:
            die(E_USAGE, "--report takes no other argument")
        remove_targets(token)
        after = current_privileges(token)
        print("parent token (inherited): %s" % describe(before))
        print("child token (after removal): %s" % describe(after))
        return 0

    if argv[:1] != ["--"] or len(argv) < 2:
        die(E_USAGE, "usage: win-restricted-run.py --report | -- <prog> [args]")
    command = argv[1:]

    remove_targets(token)
    after = current_privileges(token)
    still = [n for n in TARGETS if n in after]
    if still:
        die(E_STILL_THERE,
            "NOT VERIFIED: %s still on this token after SE_PRIVILEGE_REMOVED "
            "(before: %s) — nothing was run"
            % (", ".join(still), describe(before)))

    # The caller reaches native Python with MSYS2_ARG_CONV_EXCL='*' so that its
    # POSIX arguments survive. That override is for THAT call only: the child
    # is a Git Bash that runs native git, and it must keep the normal
    # conversion rules.
    env = dict(os.environ)
    env.pop("MSYS2_ARG_CONV_EXCL", None)
    try:
        # stdout/stderr are inherited, so the caller reads the command's own
        # output and its own exit status, with nothing added or swallowed.
        return subprocess.call(command, env=env)
    except OSError as e:
        die(E_SPAWN, "could not start %r: %s" % (command[0], e))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
