"""Focused runtime regressions. Run: python -m unittest discover -s tests -v."""
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


KIT = Path(os.environ.get("SDLC_TEST_KIT", Path(__file__).resolve().parents[1])).resolve()
spec = importlib.util.spec_from_file_location("sdlc_runner", KIT / "tools" / "_run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
BASH = shutil.which("bash")


def shell(script):
    env = dict(os.environ, SDLC_TEST_KIT=KIT.as_posix())
    with tempfile.TemporaryDirectory(prefix="sdlc-runtime-") as directory:
        return subprocess.run([BASH, "-c", script], cwd=directory, env=env,
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=90)


class ProcessGroups(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "real POSIX process groups require Linux/macOS")
    def test_real_group_survives_leader_and_both_cleanup_paths_stop_children(self):
        for cleanup in ("runtime", "timeout"):
            with self.subTest(cleanup=cleanup), tempfile.TemporaryDirectory() as directory:
                leader = subprocess.Popen(
                    [sys.executable, "-c", "import time; time.sleep(60)"],
                    preexec_fn=os.setpgrp)
                child = stopper = None
                try:
                    child = subprocess.Popen(
                        [sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(60)"],
                        preexec_fn=lambda: os.setpgid(0, leader.pid),
                        stdout=subprocess.PIPE, text=True)
                    self.assertEqual(child.stdout.readline().strip(), "ready")
                    leader.terminate()
                    leader.wait(timeout=3)
                    self.assertTrue(runner._group_alive(leader.pid))
                    if cleanup == "runtime":
                        pidfile = Path(directory) / "launch.pid"
                        pidfile.write_text(str(leader.pid))
                        stopper = subprocess.Popen(
                            [sys.executable, str(KIT / "tools" / "_run.py"),
                             "stop", "--pidfile", str(pidfile), "--timeout", "1"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)
                    else:
                        runner._stop(leader)
                    self.assertNotEqual(child.wait(timeout=4), 0)
                    if stopper:
                        output, _ = stopper.communicate(timeout=3)
                        self.assertEqual(stopper.returncode, 0, output)
                    self.assertFalse(runner._group_alive(leader.pid))
                finally:
                    try:
                        os.killpg(leader.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    for proc in (leader, child, stopper):
                        if proc:
                            if proc.poll() is None:
                                proc.kill()
                            proc.wait(timeout=3)
                            if proc.stdout:
                                proc.stdout.close()

    def test_alive_uses_recorded_group_after_leader_exit(self):
        with patch.object(runner, "WINDOWS", False), \
             patch.object(runner.os, "getpgid", side_effect=ProcessLookupError,
                          create=True), \
             patch.object(runner.os, "killpg", create=True) as killpg:
            self.assertTrue(runner._group_alive(987654321))
            killpg.assert_called_once_with(987654321, 0)

    def test_stop_signals_recorded_group_after_leader_exit(self):
        with patch.object(runner, "WINDOWS", False), \
             patch.object(runner.os, "getpgid", side_effect=ProcessLookupError,
                          create=True), \
             patch.object(runner.os, "killpg", create=True) as killpg:
            self.assertTrue(runner._kill_tree(987654321, signal.SIGTERM))
            killpg.assert_called_once_with(987654321, signal.SIGTERM)

    def test_timeout_kills_surviving_children_after_leader_exits(self):
        proc = unittest.mock.Mock(pid=987654321)
        proc.wait.return_value = 0
        with patch.object(runner, "SIGKILL", 9), \
             patch.object(runner, "_kill_tree") as kill_tree, \
             patch.object(runner, "_group_alive", return_value=True):
            runner._stop(proc)
            self.assertIn(unittest.mock.call(proc.pid, runner.SIGKILL),
                          kill_tree.call_args_list)


@unittest.skipUnless(BASH, "bash is required")
class Verification(unittest.TestCase):
    def test_doctor_immediate_and_retry_success(self):
        result = shell(r'''
set -eu
kit="$SDLC_TEST_KIT"
git init -q .
for slug in immediate retry; do
  mkdir -p ".sdlc/work/$slug"
  printf -- '- Track: compact\n## Success criteria\n- [ ] O1: works\n' > ".sdlc/work/$slug/intent.md"
done
printf 'doctor_timeout: 08\ndoctor_attempt_timeout: 3\ndoctor: echo ready\ncheck: O1 | unit | true\n' > .sdlc/verify.md
bash "$kit/tools/verify.sh" run immediate
printf 'doctor_timeout: 09\ndoctor_attempt_timeout: 3\ndoctor: if [ -f .sdlc/retried ]; then echo ready; else touch .sdlc/retried; exit 1; fi\ncheck: O1 | unit | true\n' > .sdlc/verify.md
bash "$kit/tools/verify.sh" run retry
echo 'ok: immediate and retry readiness both succeed'
''')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_doctor_deadline_caps_attempts_and_includes_command_time(self):
        result = shell(r'''
set -eu
kit="$SDLC_TEST_KIT"
git init -q .
mkdir -p .sdlc/work/deadline
printf -- '- Track: compact\n## Success criteria\n- [ ] O1: works\n' > .sdlc/work/deadline/intent.md
cat > .sdlc/verify.md <<'EOF'
profile: advisory
doctor_timeout: 1
doctor_attempt_timeout: 3
doctor: echo doctor-started; sleep 30; echo doctor-finished; exit 1
check: O1 | unit | true
EOF
if bash "$kit/tools/verify.sh" run deadline; then echo 'unexpected pass'; exit 1; fi
log=.sdlc/work/deadline/scratch/verify/doctor.log
[ "$(grep -c doctor-started "$log")" = 1 ] || { cat "$log"; echo 'doctor ran after its deadline'; exit 1; }
if grep -q doctor-finished "$log"; then cat "$log"; echo 'doctor attempt exceeded total budget'; exit 1; fi
grep -q 'timed out after 1s' "$log" || { cat "$log"; echo 'doctor attempt was not capped'; exit 1; }
echo 'ok: doctor attempt respects the total deadline'
''')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_baseline_logs_are_required_for_both_proof_paths(self):
        result = shell(r'''
set -eu
kit="$SDLC_TEST_KIT"
. "$kit/gates/_common.sh"
. "$kit/gates/_auto.sh"
git init -q .
git -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm base
mkdir -p .sdlc/work/proof/scratch/verify-base
printf -- '- Track: compact\n## Success criteria\n- [ ] O1: works\n' > .sdlc/work/proof/intent.md
printf 'check: suite | unit | false\ntest_paths: tests/*\n' > .sdlc/verify.md
log=.sdlc/work/proof/scratch/verify-base/suite.log
printf 'the observed failure\n' > "$log"
cmd=$(printf false | sdlc_sha256_stdin)
digest=$(sdlc_sha256_file "$log")
cat > .sdlc/work/proof/verify-baseline.md <<EOF
baseline_schema: sdlc-kit/verify-baseline@1
base_sha: $(git rev-parse HEAD)
recipe_digest: $(sdlc_verify_recipe_digest)
feature_recipe_digest: none
check: suite | unit | $cmd | 1 | base | $digest | $log
EOF
sdlc_verify_baseline_usable proof || { echo 'valid baseline refused'; exit 1; }
sdlc_verify_preexisting_ok proof suite unit "$cmd" '' 1 || { echo 'valid pre-existing proof refused'; exit 1; }
printf 'rewritten failure\n' > "$log"
if sdlc_verify_baseline_usable proof; then echo 'rewritten baseline log accepted'; exit 1; fi
if sdlc_verify_preexisting_ok proof suite unit "$cmd" '' 1; then echo 'rewritten pre-existing proof accepted'; exit 1; fi
printf 'the observed failure\n' > "$log"
rm "$log"
if sdlc_verify_baseline_usable proof; then echo 'missing baseline log accepted'; exit 1; fi
# Must-fail proof shares that validator and must refuse the same missing log.
printf 'the observed failure\n' > "$log"
printf 'check: O1.regression | unit | false | must-fail-on-base\n' > .sdlc/work/proof/verify.md
sed -i.bak "s/^feature_recipe_digest: .*/feature_recipe_digest: $(sdlc_verify_feature_recipe_digest proof)/" .sdlc/work/proof/verify-baseline.md
sed -i.bak 's/^check: suite /check: O1.regression /' .sdlc/work/proof/verify-baseline.md
printf 'test_files: 1\ntest_files_digest: %s\n' "$(sdlc_verify_test_files_digest HEAD)" >> .sdlc/work/proof/verify-baseline.md
out=$(sdlc_verify_baseline_issue proof)
[ -z "$out" ] || { echo "valid must-fail proof refused: $out"; exit 1; }
rm "$log"
out=$(sdlc_verify_baseline_issue proof)
case "$out" in missing\|*) ;; *) echo "missing must-fail proof accepted: $out"; exit 1;; esac
echo 'ok: baseline proof requires unchanged logs'
''')
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
