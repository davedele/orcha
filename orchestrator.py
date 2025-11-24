#!/usr/bin/env python
import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import TypedDict

from typing_extensions import Annotated
import operator

import fcntl
import contextlib
from langgraph.graph import StateGraph, START, END


# -----------------------------
# Locking
# -----------------------------

@contextlib.contextmanager
def workspace_lock(workspace_root: Path):
    lock_file = workspace_root / ".orcha.lock"
    # Ensure lock file exists
    if not lock_file.exists():
        lock_file.touch()
    
    f = open(lock_file, "r+")
    try:
        # Try to acquire an exclusive lock, non-blocking
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except BlockingIOError:
        print(f"[ERROR] Could not acquire lock on {lock_file}.")
        print("Another orchestrator instance is likely running on this workspace.")
        sys.exit(1)
    finally:
        # Unlock and close
        try:
            fcntl.flock(f, fcntl.LOCK_UN)
        except:
            pass
        f.close()


# -----------------------------
# Types / State
# -----------------------------


class OrchestratorState(TypedDict, total=False):
    # required inputs
    workspace_root: str
    target_file: str        # e.g. "src/UserService.ts"
    original_instruction: str # The clean, original user prompt
    instruction: str        # The current active instruction (may include error logs)
    branch_name: str        # e.g. "refactor/user-service"
    test_cmd: str           # shell string, e.g. "npm test"
    refactor_cmd: str       # shell string, e.g. "bun Refactor.ts"
    model_spec: str         # optional Refactor.ts model, e.g. "g"

    # derived / runtime
    base_branch: str
    tests_passed: bool
    refactor_exit_code: int
    retry_count: int
    max_retries: int
    last_test_error: str
    force_branch: bool

    logs: Annotated[list[str], operator.add]


# -----------------------------
# Helpers
# -----------------------------


def run(cmd, cwd: Path, check=True, capture_output=False) -> subprocess.CompletedProcess:
    if isinstance(cmd, str):
        cmd_list = shlex.split(cmd)
    else:
        cmd_list = cmd
    proc = subprocess.run(
        cmd_list,
        cwd=str(cwd),
        check=check,
        text=True,
        capture_output=capture_output,
    )
    return proc


def run_capture(cmd, cwd: Path) -> str:
    if isinstance(cmd, str):
        cmd_list = shlex.split(cmd)
    else:
        cmd_list = cmd
    out = subprocess.check_output(cmd_list, cwd=str(cwd), text=True)
    return out.strip()


def git(cmd_args, cwd: Path, check=True) -> subprocess.CompletedProcess:
    return run(["git"] + cmd_args, cwd=cwd, check=check, capture_output=True)


def ensure_git_clean(cwd: Path):
    status = run_capture(["git", "status", "--porcelain"], cwd)
    if status.strip():
        raise RuntimeError("Git working tree not clean. Commit or stash before running orchestrator.")


def detect_newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def get_comment_prefix(filename: str) -> str:
    ext = Path(filename).suffix.lower()
    if ext in [".py", ".rb", ".sh", ".yaml", ".yml", ".dockerfile"]:
        return "#"
    if ext in [".sql", ".lua"]:
        return "--"
    return "//"


def is_import_comment_line(line: str) -> bool:
    stripped = line.strip()
    if stripped.startswith("//[") and stripped.endswith("]"):
        return True
    if stripped.startswith("#[") and stripped.endswith("]"):
        return True
    if stripped.startswith("--[") and stripped.endswith("]"):
        return True
    if stripped.startswith("#include") and '"' in stripped:
        return True
    return False


def is_instruction_line(line: str) -> bool:
    if is_import_comment_line(line):
        return False
    stripped = line.lstrip()
    if not stripped:
        return False
    if stripped.startswith("//"):
        return True
    if stripped.startswith("--"):
        return True
    if stripped.startswith("#"):
        return True
    return False


def rewrite_trailing_instruction_block(original: str, instruction: str, comment_prefix: str = "//") -> str:
    newline = detect_newline(original)
    lines = original.replace("\r\n", "\n").split("\n")

    # trim trailing whitespace-only lines
    end = len(lines) - 1
    while end >= 0 and not lines[end].strip():
        end -= 1

    if end < 0:
        body_lines = []
    else:
        idx = end
        while idx >= 0 and is_instruction_line(lines[idx]):
            idx -= 1
        body_lines = lines[: idx + 1]

    while body_lines and not body_lines[-1].strip():
        body_lines.pop()

    result_lines = list(body_lines)
    if result_lines:
        result_lines.append("")

    for raw in instruction.splitlines():
        striped = raw.rstrip()
        if not striped:
            result_lines.append(comment_prefix)
        else:
            result_lines.append(f"{comment_prefix} {striped}")

    text = "\n".join(result_lines)
    if not text.endswith("\n"):
        text += "\n"

    if newline == "\r\n":
        text = text.replace("\n", "\r\n")
    return text


def inject_instruction(workspace_root: Path, target_file: str, instruction: str):
    abs_path = (workspace_root / target_file).resolve()
    if not abs_path.is_file():
        raise FileNotFoundError(f"Target file not found: {abs_path}")
    text = abs_path.read_text(encoding="utf-8")
    prefix = get_comment_prefix(target_file)
    new_text = rewrite_trailing_instruction_block(text, instruction, comment_prefix=prefix)
    abs_path.write_text(new_text, encoding="utf-8")


# -----------------------------
# LangGraph nodes
# -----------------------------


def node_prepare_repo(state: OrchestratorState) -> OrchestratorState:
    root = Path(state["workspace_root"]).resolve()
    logs = state.get("logs", [])
    logs.append(f"[prepare_repo] root={root}")

    if not (root / ".git").is_dir():
        raise RuntimeError(f".git not found under {root}")

    ensure_git_clean(root)

    base_branch = run_capture(["git", "rev-parse", "--abbrev-ref", "HEAD"], root)
    logs.append(f"[prepare_repo] base_branch={base_branch}")

    branch_name = state["branch_name"]

    force = state.get("force_branch", False)

    # Create branch but don't check it out if it exists (safety)
    try:
        git(["checkout", "-b", branch_name], cwd=root)
        logs.append(f"[prepare_repo] created branch {branch_name}")
    except subprocess.CalledProcessError:
        if force:
            logs.append(f"[prepare_repo] branch {branch_name} exists, forcing recreation")
            try:
                # If we are on the branch we want to delete, we need to move off it.
                # We are currently on base_branch (checked at start of function).
                # But if base_branch IS branch_name (e.g. user started on refactor branch),
                # we can't delete it easily without switching to something else.
                # Assuming standard flow where base_branch != branch_name.
                git(["branch", "-D", branch_name], cwd=root)
                git(["checkout", "-b", branch_name], cwd=root)
                logs.append(f"[prepare_repo] recreated branch {branch_name}")
            except subprocess.CalledProcessError as e:
                raise RuntimeError(f"Failed to force-recreate branch {branch_name}: {e}")
        else:
            raise RuntimeError(f"Branch {branch_name} already exists. Delete it first.")

    return {
        "workspace_root": str(root),
        "base_branch": base_branch,
        "branch_name": branch_name,
        "logs": logs,
    }


def node_inject_instruction(state: OrchestratorState) -> OrchestratorState:
    root = Path(state["workspace_root"])
    target_file = state["target_file"]
    instruction = state["instruction"]
    logs = state.get("logs", [])
    logs.append(f"[inject_instruction] file={target_file}")
    inject_instruction(root, target_file, instruction)
    return {"logs": logs}


def node_run_refactor(state: OrchestratorState) -> OrchestratorState:
    root = Path(state["workspace_root"])
    target_file = state["target_file"]
    refactor_cmd = state["refactor_cmd"]
    model_spec = state.get("model_spec", "").strip()
    logs = state.get("logs", [])

    base_cmd = shlex.split(refactor_cmd)
    cmd = base_cmd + [target_file]
    if model_spec:
        cmd.append(model_spec)

    logs.append(f"[run_refactor] cmd={' '.join(cmd)}")

    try:
        proc = run(cmd, cwd=root, check=False, capture_output=True)
        code = proc.returncode
        logs.append(f"[run_refactor] exit={code}")
        if proc.stdout:
            logs.append(f"[run_refactor] stdout: {proc.stdout.strip()}")
        if proc.stderr:
            logs.append(f"[run_refactor] stderr: {proc.stderr.strip()}")
        return {
            "refactor_exit_code": code,
            "logs": logs,
        }
    except Exception as e:
        logs.append(f"[run_refactor] EXCEPTION {e}")
        return {
            "refactor_exit_code": 1,
            "tests_passed": False,
            "logs": logs,
        }


def node_run_tests(state: OrchestratorState) -> OrchestratorState:
    root = Path(state["workspace_root"])
    logs = state.get("logs", [])

    if state.get("refactor_exit_code", 0) != 0:
        logs.append("[run_tests] skipped (refactor failed)")
        return {
            "tests_passed": False,
            "last_test_error": "Refactor tool failed; tests were not run.",
            "logs": logs,
        }

    test_cmd = state["test_cmd"]
    logs.append(f"[run_tests] cmd={test_cmd}")
    try:
        proc = run(test_cmd, cwd=root, check=False, capture_output=True)
        if proc.returncode == 0:
            logs.append("[run_tests] PASS")
            return {
                "tests_passed": True,
                "last_test_error": "",
                "logs": logs,
            }
        else:
            err_snip = (proc.stderr or proc.stdout or "").strip()
            if len(err_snip) > 2000:
                err_snip = err_snip[-2000:]
            logs.append(f"[run_tests] FAIL exit={proc.returncode}")
            return {
                "tests_passed": False,
                "last_test_error": err_snip,
                "logs": logs,
            }
    except Exception as e:
        logs.append(f"[run_tests] EXCEPTION {e}")
        return {
            "tests_passed": False,
            "last_test_error": str(e),
            "logs": logs,
        }


def node_attempt_fix(state: OrchestratorState) -> OrchestratorState:
    logs = state.get("logs", [])
    current_retries = state.get("retry_count", 0)
    max_retries = state.get("max_retries", 0)
    last_error = state.get("last_test_error", "").strip()

    if not last_error:
        last_error = "Tests failed, but no error output was captured."

    if len(last_error) > 1500:
        last_error = last_error[-1500:]

    # FIX: Use original_instruction as base to avoid bloat
    base_instruction = state["original_instruction"]

    new_instruction = (
        f"{base_instruction}\n\n"
        f"PREVIOUS ATTEMPT FAILED TESTS.\n"
        f"Use the following error output to fix the implementation and make tests pass:\n"
        f"{last_error}\n"
        f"Do NOT undo already-correct refactors; only adjust what is needed to fix the failing tests."
    )

    logs.append(
        f"[attempt_fix] Retry {current_retries + 1}/{max_retries}"
    )

    return {
        "instruction": new_instruction,
        "retry_count": current_retries + 1,
        "logs": logs,
    }


def node_finalize(state: OrchestratorState) -> OrchestratorState:
    root = Path(state["workspace_root"])
    base_branch = state["base_branch"]
    branch_name = state["branch_name"]
    tests_passed = bool(state.get("tests_passed", False))
    refactor_exit_code = state.get("refactor_exit_code", 0)
    logs = state.get("logs", [])

    if not tests_passed or refactor_exit_code != 0:
        logs.append("[finalize] failure state; rolling back branch")
        # Force cleanup
        git(["reset", "--hard"], cwd=root)
        git(["clean", "-fd"], cwd=root)
        git(["checkout", base_branch], cwd=root)
        git(["branch", "-D", branch_name], cwd=root)
        logs.append(f"[finalize] rolled back and deleted branch {branch_name}")
        return {"logs": logs}

    target_file = state["target_file"]
    logs.append("[finalize] tests passed; committing and merging")

    git(["add", "."], cwd=root)
    git(["commit", "-m", f"AI refactor {target_file}"], cwd=root)
    git(
        ["checkout", base_branch],
        cwd=root,
    )
    git(
        [
            "merge",
            "--no-ff",
            branch_name,
            "-m",
            f"Merge {branch_name} (AI refactor {target_file})",
        ],
        cwd=root,
    )
    git(["branch", "-d", branch_name], cwd=root)

    logs.append(
        f"[finalize] merged {branch_name} -> {base_branch} and deleted branch"
    )
    return {"logs": logs}


# -----------------------------
# Routing
# -----------------------------


def route_after_tests(state: OrchestratorState) -> str:
    # If refactor itself failed, no point looping; finalize (rollback).
    if state.get("refactor_exit_code", 0) != 0:
        return "finalize"

    if state.get("tests_passed"):
        return "finalize"

    retries = state.get("retry_count", 0)
    max_retries = state.get("max_retries", 0)
    if retries < max_retries:
        return "attempt_fix"

    return "finalize"


# -----------------------------
# Build graph
# -----------------------------


def build_graph():
    graph = StateGraph(OrchestratorState)
    graph.add_node("prepare_repo", node_prepare_repo)
    graph.add_node("inject_instruction", node_inject_instruction)
    graph.add_node("run_refactor", node_run_refactor)
    graph.add_node("run_tests", node_run_tests)
    graph.add_node("attempt_fix", node_attempt_fix)
    graph.add_node("finalize", node_finalize)

    graph.add_edge(START, "prepare_repo")
    graph.add_edge("prepare_repo", "inject_instruction")
    graph.add_edge("inject_instruction", "run_refactor")
    graph.add_edge("run_refactor", "run_tests")

    graph.add_conditional_edges(
        "run_tests",
        route_after_tests,
        {
            "finalize": "finalize",
            "attempt_fix": "attempt_fix",
        },
    )

    graph.add_edge("attempt_fix", "inject_instruction")
    graph.add_edge("finalize", END)

    return graph.compile()


# -----------------------------
# CLI entry point
# -----------------------------


def parse_args():
    p = argparse.ArgumentParser(
        description="LangGraph-based orchestrator for Refactor.ts AI refactors with self-healing loop."
    )
    p.add_argument(
        "-f",
        "--file",
        required=True,
        help="Target source file relative to workspace root (e.g. src/UserService.ts).",
    )
    p.add_argument(
        "-i",
        "--instruction",
        required=True,
        help="Natural-language refactor instruction for the trailing comment block.",
    )
    p.add_argument(
        "-b",
        "--branch",
        help="Refactor branch name (default: refactor/<file-stem>).",
    )
    p.add_argument(
        "-r",
        "--root",
        default=".",
        help="Workspace root (default: current directory).",
    )
    p.add_argument(
        "--test-cmd",
        default="npm test",
        help="Shell command used to run tests (default: 'npm test').",
    )
    p.add_argument(
        "--refactor-cmd",
        default=os.environ.get("ORCHA_REFACTOR_CMD", "bun Refactor.ts"),
        help="Command to invoke Refactor.ts (e.g. 'refactor' if installed globally, or 'bun Refactor.ts').",
    )
    p.add_argument(
        "--model-spec",
        default="",
        help="Optional model spec passed as 2nd arg to Refactor.ts (e.g. 'g').",
    )
    p.add_argument(
        "--max-retries",
        type=int,
        default=2,
        help="Max self-healing attempts after failing tests (default: 2).",
    )
    p.add_argument(
        "--force-branch",
        action="store_true",
        help="Force creation of branch if it already exists (deletes existing branch).",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Output final state as JSON (useful for agent integration).",
    )
    return p.parse_args()


def main():
    args = parse_args()
    workspace_root = str(Path(args.root).resolve())
    file_path = Path(args.file)
    default_branch = f"refactor/{file_path.stem}"
    branch_name = args.branch or default_branch

    # Acquire lock on workspace to prevent concurrent runs
    with workspace_lock(Path(workspace_root)):
        initial_state: OrchestratorState = {
            "workspace_root": workspace_root,
            "target_file": str(file_path.as_posix()),
            "original_instruction": args.instruction, # Stored separately to prevent bloat
            "instruction": args.instruction,
            "branch_name": branch_name,
            "test_cmd": args.test_cmd,
            "refactor_cmd": args.refactor_cmd,
            "model_spec": args.model_spec,
            "retry_count": 0,
            "max_retries": args.max_retries,
            "last_test_error": "",
            "force_branch": args.force_branch,
            "logs": [],
        }

        app = build_graph()
        
        # Safety Wrapper
        try:
            final_state = app.invoke(initial_state)
            
            if args.json:
                output = {
                    "tests_passed": final_state.get("tests_passed", False),
                    "refactor_exit_code": final_state.get("refactor_exit_code", 0),
                    "retry_count": final_state.get("retry_count", 0),
                    "last_test_error": final_state.get("last_test_error", ""),
                    "logs": final_state.get("logs", []),
                }
                print(json.dumps(output, indent=2))
            else:
                for line in final_state.get("logs", []):
                    print(line)
                
        except Exception as e:
            if args.json:
                error_output = {
                    "tests_passed": False,
                    "refactor_exit_code": 1,
                    "retry_count": 0,
                    "last_test_error": str(e),
                    "logs": [f"[CRITICAL ERROR] Orchestrator crashed: {e}"],
                    "status": "crash"
                }
                print(json.dumps(error_output))
            else:
                print(f"\n[CRITICAL ERROR] Orchestrator crashed: {e}")
                # Attempt emergency cleanup to avoid leaving user on a dirty branch
                try:
                    print("Attempting emergency cleanup...")
                    print(f"  You may be on temporary branch '{branch_name}'.")
                    print("   Please run: git checkout - && git branch -D " + branch_name)
                except:
                    pass
            sys.exit(1)

        # Check for failure in the graph execution (tests failed or refactor failed)
        # If we reached here, no exception was thrown, but the pipeline might have "failed" logically.
        exit_code = 0
        if not final_state.get("tests_passed", False) or final_state.get("refactor_exit_code", 0) != 0:
            exit_code = 1
        
        sys.exit(exit_code)


if __name__ == "__main__":
    main()