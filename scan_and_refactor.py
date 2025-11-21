#!/usr/bin/env python3
import os
import sys
import argparse
import json
import subprocess
from pathlib import Path
from typing import List

from config import IGNORE_DIRS


def is_ignored(path: Path) -> bool:
    return any(part in IGNORE_DIRS for part in path.parts)


def is_test_file(p: Path) -> bool:
    name = p.name
    stem = p.stem
    # basic heuristics; extend if needed
    if stem.endswith(".spec") or stem.endswith(".test") or stem.endswith(".e2e"):
        return True
    if name.endswith(".spec.ts") or name.endswith(".test.ts") or name.endswith(".e2e.ts"):
        return True
    if name.endswith(".spec.tsx") or name.endswith(".test.tsx") or name.endswith(".e2e.tsx"):
        return True
    return False


def find_targets(root: Path, ext: str) -> List[Path]:
    targets: List[Path] = []
    for p in root.rglob(f"*{ext}"):
        if not p.is_file():
            continue
        if is_ignored(p):
            continue
        if is_test_file(p):
            continue
        targets.append(p)
    # small files first
    targets.sort(key=lambda x: x.stat().st_size)
    return targets


def branch_name_for(rel: Path) -> str:
    """
    Build a unique, deterministic branch name from a relative path.

    src/UserService.ts -> refactor/src__UserService
    src/features/auth/UserService.ts -> refactor/src__features__auth__UserService
    """
    stem_path = rel.with_suffix("")  # drop extension
    # use posix-style, then replace / with __
    posix_str = stem_path.as_posix()
    sanitized = posix_str.replace("/", "__").replace(" ", "_")
    # git branch name length guard
    if len(sanitized) > 150:
        sanitized = sanitized[-150:]
    return f"refactor/{sanitized}"


def append_history(log_file: Path, entry: dict):
    with open(log_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")


def load_successful_paths(log_file: Path) -> set:
    success = set()
    if not log_file.exists():
        return success
    with open(log_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                if data.get("status") == "success":
                    success.add(data.get("path"))
            except json.JSONDecodeError:
                pass
    return success


def main():
    parser = argparse.ArgumentParser(
        description="Mass run AI refactor across a codebase using orchestrator.py."
    )
    parser.add_argument(
        "dir",
        help="Target directory to scan (e.g., src)",
    )
    parser.add_argument(
        "-i",
        "--instruction",
        required=True,
        help="Refactor instruction to apply to ALL files",
    )
    parser.add_argument(
        "-e",
        "--ext",
        default=".ts",
        help="File extension to target (default: .ts)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Scan files but do not run orchestrator",
    )
    parser.add_argument(
        "--resume-from",
        help="Resume processing from this file path (skips all files before it).",
    )
    parser.add_argument(
        "--skip-successful",
        action="store_true",
        help="Skip files that are already marked as 'success' in refactor_history.jsonl.",
    )
    # pass-through options to orchestrator
    parser.add_argument(
        "--test-cmd",
        default=None,
        help="Override test command for orchestrator (e.g. 'npm test').",
    )
    parser.add_argument(
        "--refactor-cmd",
        default=None,
        help="Override refactor command (e.g. 'bun Refactor.ts').",
    )
    parser.add_argument(
        "--model-spec",
        default=None,
        help="Optional model spec passed to Refactor.ts (e.g. 'g').",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=None,
        help="Override orchestrator max self-heal retries.",
    )

    args = parser.parse_args()

    # FIX: Locate orchestrator relative to THIS script
    orchestrator_script = Path(__file__).parent / "orchestrator.py"
    
    if not orchestrator_script.exists():
        print(f"CRITICAL: Orchestrator script not found at {orchestrator_script}", file=sys.stderr)
        sys.exit(1)

    root = Path(args.dir).resolve()
    if not root.exists():
        print(f"Error: directory {root} does not exist", file=sys.stderr)
        sys.exit(1)

    targets = find_targets(root, args.ext)
    if not targets:
        print(f"No *{args.ext} files found under {root}")
        sys.exit(0)

    print(f"Scanning under: {root}")
    print(f"Found {len(targets)} target file(s).")

    # History / Resume logic
    history_file = Path("refactor_history.jsonl")
    successful_paths = set()
    if args.skip_successful:
        successful_paths = load_successful_paths(history_file)
        print(f"Loaded {len(successful_paths)} successful paths from history.")

    skipping = False
    if args.resume_from:
        skipping = True
        print(f"Resuming from: {args.resume_from} (skipping prior files)")

    success_count = 0
    fail_count = 0
    skipped_count = 0

    for p in targets:
        rel = p.relative_to(root)
        rel_str = rel.as_posix()

        # Resume logic
        if skipping:
            if rel_str == args.resume_from or str(p) == args.resume_from:
                skipping = False
            else:
                # skipped_count += 1 # Optional: count skipped by resume?
                continue

        # Skip successful logic
        if args.skip_successful and rel_str in successful_paths:
            print(f"[SKIP] {rel} (already successful)")
            skipped_count += 1
            continue

        branch = branch_name_for(rel)
        print(f"\n=== Refactor target: {rel} (branch: {branch}) ===")

        if args.dry_run:
            continue

        cmd = [
            sys.executable,
            str(orchestrator_script),
            "--file",
            rel.as_posix(),
            "--instruction",
            args.instruction,
            "--root",
            str(root),
            "--branch",
            branch,
            "--json",  # Enable JSON output
        ]

        if args.test_cmd:
            cmd.extend(["--test-cmd", args.test_cmd])
        if args.refactor_cmd:
            cmd.extend(["--refactor-cmd", args.refactor_cmd])
        if args.model_spec:
            cmd.extend(["--model-spec", args.model_spec])
        if args.max_retries is not None:
            cmd.extend(["--max-retries", str(args.max_retries)])

        # Run orchestrator
        try:
            # We use capture_output=True to get the JSON
            proc = subprocess.run(cmd, capture_output=True, text=True)
            
            # Try to parse JSON output
            result = {}
            try:
                result = json.loads(proc.stdout)
            except json.JSONDecodeError:
                # Fallback if something printed before JSON or crash
                print(f"Warning: Could not parse JSON output from orchestrator.")
                print("STDOUT:", proc.stdout)
                print("STDERR:", proc.stderr)
                result = {
                    "tests_passed": False,
                    "refactor_exit_code": proc.returncode,
                    "last_test_error": "Orchestrator output parse error",
                }

            tests_passed = result.get("tests_passed", False)
            refactor_code = result.get("refactor_exit_code", 0)
            last_error = result.get("last_test_error", "")
            
            is_success = (proc.returncode == 0) and tests_passed and (refactor_code == 0)
            
            log_entry = {
                "path": rel_str,
                "exit_code": proc.returncode,
                "tests_passed": tests_passed,
                "refactor_exit_code": refactor_code,
                "status": "success" if is_success else "failure",
                "error_summary": last_error[:200] if last_error else ""
            }
            append_history(history_file, log_entry)

            if is_success:
                print(f"[OK] {rel}")
                success_count += 1
            else:
                reason = "Unknown"
                if refactor_code != 0:
                    reason = f"Refactor tool failed (exit {refactor_code})"
                elif not tests_passed:
                    reason = "Tests failed"
                    if last_error:
                        # Show first line of error or short summary
                        short_err = last_error.split('\n')[0][:80]
                        reason += f": {short_err}..."
                
                print(f"[FAIL] {rel} ({reason})")
                fail_count += 1

        except Exception as e:
            print(f"[CRITICAL] Failed to run orchestrator for {rel}: {e}")
            fail_count += 1

    print("\n=== Summary ===")
    print(f"Root:    {root}")
    print(f"Ext:     {args.ext}")
    print(f"Total:   {len(targets)}")
    print(f"Success: {success_count}")
    print(f"Failed:  {fail_count}")
    print(f"Skipped: {skipped_count}")


if __name__ == "__main__":
    main()
