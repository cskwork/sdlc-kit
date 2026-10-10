"""User-visible completion through six independently invokable CLI scenarios."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

scenario = sys.argv[1]
with tempfile.TemporaryDirectory() as tmp:
    db = Path(tmp) / "tasks.json"
    def run(*args, module=False):
        entry = ["-m", "taskdesk"] if module else ["taskdesk.py"]
        return subprocess.run([sys.executable, *entry, "--db", str(db), *args],
                              text=True, capture_output=True)
    def ok(*args, module=False):
        result = run(*args, module=module)
        assert result.returncode == 0, (scenario, args, result.returncode, result.stderr)
        return json.loads(result.stdout)
    if scenario in ("happy", "entry"):
        task = ok("add", "write release notes")
        assert ok("complete", str(task["id"]), module=scenario == "entry")["done"] is True
        assert ok("list")[0]["done"] is True
    elif scenario == "boundary":
        ok("add", "first")
        ok("add", "last")
        assert ok("complete", "2")["id"] == 2
        assert [task["done"] for task in ok("list")] == [False, True]
    elif scenario == "negative":
        ok("add", "keep")
        before = db.read_bytes()
        for bad in ("0", "-1", "999", "not-a-number"):
            result = run("complete", bad)
            assert result.returncode == 2, (bad, result)
            assert "error:" in result.stderr
            assert db.read_bytes() == before, "invalid input mutated persisted tasks"
    elif scenario == "state":
        db.write_text(json.dumps([{"id": 1, "title": "existing", "done": False}]))
        assert ok("complete", "1")["title"] == "existing"
        assert json.loads(db.read_text())[0]["done"] is True
    elif scenario == "context":
        ok("add", "한글 task")
        first = ok("complete", "1")
        assert ok("complete", "1") == first, "completion must be idempotent"
        assert len(ok("list")) == 1
    else:
        raise AssertionError("unknown scenario: " + scenario)
print("PASS completion " + scenario + ": actual CLI output and persisted state checked")
