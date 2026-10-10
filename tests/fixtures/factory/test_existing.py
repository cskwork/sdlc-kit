"""Unchanged baseline behavior, invoked as the project's shared unit check."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory() as tmp:
    db = Path(tmp) / "tasks.json"
    def run(*args):
        return subprocess.run([sys.executable, "taskdesk.py", "--db", str(db), *args],
                              text=True, capture_output=True, check=True)
    assert json.loads(run("list").stdout) == []
    assert json.loads(run("add", "first").stdout) == {"id": 1, "title": "first", "done": False}
    assert json.loads(run("list").stdout) == [{"id": 1, "title": "first", "done": False}]
print("PASS existing: add/list persist the task across CLI processes")
