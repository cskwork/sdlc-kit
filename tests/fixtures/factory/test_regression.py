"""Regression and reach variants for sparse persisted task IDs; real CLI only."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

scenario = sys.argv[1] if len(sys.argv) > 1 else "happy"
with tempfile.TemporaryDirectory() as tmp:
    db = Path(tmp) / "tasks.json"
    legacy = [{"id": 1, "title": "kept", "done": False},
              {"id": 3, "title": "legacy third", "done": True}]
    if scenario == "boundary":
        legacy = [{"id": 2147483647, "title": "large ID", "done": False}]
    elif scenario == "context":
        legacy = [{"id": 8, "title": "out of order", "done": False},
                  {"id": 2, "title": "한글", "done": True}]
    assert scenario in {"happy", "boundary", "negative", "entry", "state", "context"}
    db.write_text(json.dumps(legacy))
    def run(*args):
        entry = ["-m", "taskdesk"] if scenario == "entry" else ["taskdesk.py"]
        return subprocess.run([sys.executable, *entry, "--db", str(db), *args],
                              text=True, capture_output=True)
    def ok(*args):
        result = run(*args)
        assert result.returncode == 0, (scenario, args, result.stderr)
        return json.loads(result.stdout)
    if scenario == "negative":
        before = db.read_bytes()
        result = run("add", "  ")
        assert result.returncode == 2 and "title must not be empty" in result.stderr
        assert db.read_bytes() == before, "rejected title mutated legacy data"
    else:
        expected = max(task["id"] for task in legacy) + 1
        added = ok("add", "new after deletion")
        assert added["id"] == expected, "sparse IDs: expected next ID %s, got %s" % (expected, added["id"])
        tasks = ok("list")
        assert len({task["id"] for task in tasks}) == len(tasks), "duplicate persisted ID"
        assert tasks[:len(legacy)] == legacy, "adding changed a legacy record"
        assert ok("complete", str(expected))["title"] == "new after deletion"
        assert ok("list")[:len(legacy)] == legacy, "completion changed a legacy record"
        if scenario == "boundary":
            db.unlink()
            assert ok("add", "first")["id"] == 1, "empty state must start at 1"
print("PASS sparse IDs " + scenario + ": CLI output, unique IDs, and persisted legacy state checked")
