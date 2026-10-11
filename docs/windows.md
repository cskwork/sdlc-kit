# Windows shell preflight

Use native Git Bash for kit commands. A command that works in an interactive
terminal can fail in the agent's process: `bash` may select the WSL shim,
`python3` may select a Store alias, PATH may omit coreutils, and nested
PowerShell/Bash/Python quoting may split one argument. Preflight in the actual
process that will run checks before creating feature records or editing code.
Use an already working WSL environment only when the project selects it;
installing WSL is not a repair step.

Save this as `sdlc-preflight.sh` outside the kit, replace the three paths with
the actual project, kit and native Python paths, and launch that saved file.
Spaces remain inside quoted arguments; POSIX paths are for Bash, the Python
runner receives native paths via `cygpath`.

```bash
#!/usr/bin/env bash
set -euo pipefail
project='/d/work/my project'
kit='/d/work/sdlc-kit'
python='/c/Users/your-name/AppData/Local/Programs/Python/Python312/python.exe'
export PATH="${python%/*}:/usr/bin:/bin:$PATH"
printf 'Bash: %s\n' "$BASH_VERSION"
command -v bash sh git mktemp sed awk python
"$python" -c 'import sys; print(sys.executable); assert sys.version_info >= (3, 9)'
cd "$project"
git rev-parse --show-toplevel
git status --short
"$python" -c 'import sys; assert sys.argv[1] == "argument with spaces"; print("argument with spaces: PASS")' 'argument with spaces'
preflight=$(mktemp -d "${TMPDIR:-/tmp}/sdlc preflight.XXXXXX")
trap 'rm -rf "$preflight"' EXIT
"$python" "$(cygpath -m "$kit/tools/_run.py")" exec --timeout 10 \
  --cmd 'printf "%s\n" "runner argument with spaces"' \
  --cwd "$(cygpath -m "$project")" \
  --log "$(cygpath -m "$preflight/runner output.log")"
cat "$preflight/runner output.log"
grep -qx 'runner argument with spaces' "$preflight/runner output.log"
```

From PowerShell, use the actual Git Bash executable and a file argument:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' 'D:/work/sdlc-preflight.sh'
```

Require exit 0, the intended project root and interpreter, the space-preserved
argument and runner output. Run subsequent commands from that same shell/PATH
context. Record shell/executable paths, command, exit and deciding output; a
different shell launch needs its own preflight. Avoid nested `bash -c` strings
when a saved script already expresses the exact commands.
The preflight log lives in its own temporary directory outside the application
source and is cleaned on exit; retain the script's stdout in your run record.

If Git reports dubious ownership, verify the exact root and owner first.
For an intentionally shared checkout, scope trust to this process and this
single verified path, inside the saved script before the Git checks:

```bash
# Example for a process with no existing GIT_CONFIG_COUNT entries.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$(cygpath -m "$project")"
```

Preserve existing entries by appending at their count instead of overwriting
them. A path mismatch or unknown owner is a blocker. Do not broaden trust to
all directories, change ACLs, or write global Git configuration to get past a
failure. Fix the chosen executable/PATH or quoting, then rerun the same check.

For kit self-tests, mirror the existing CI settings with process-scoped
`core.autocrlf=false`, `core.symlinks=true`, fixture Git identity and
`MSYS=winsymlinks:nativestrict`. Native symlink permission is still required;
when absent, preserve the failing log and report the environment gap. A
passing hosted Windows job is separate evidence, never a local pass.
