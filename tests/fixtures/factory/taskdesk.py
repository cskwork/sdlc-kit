"""Small persisted CLI product for the factory lifecycle test; stdlib only."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add")
    add.add_argument("title")
    commands.add_parser("list")
    # COMPLETE_PARSER
    args = parser.parse_args()
    tasks = json.loads(args.db.read_text()) if args.db.exists() else []
    if args.command == "add":
        if not args.title.strip():
            parser.error("title must not be empty")
        next_id = len(tasks) + 1  # FIX_ID_ALLOCATION
        tasks.append({"id": next_id, "title": args.title, "done": False})
        args.db.write_text(json.dumps(tasks))
        print(json.dumps(tasks[-1]))
    elif args.command == "list":
        print(json.dumps(tasks))
    # COMPLETE_HANDLER


if __name__ == "__main__":
    main()
