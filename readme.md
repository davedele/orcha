# AI Refactoring Assembly Line

A multi-agent pipeline for orchestrating large-scale code refactors safely. This system turns a "one-off" AI coding tool into a scalable factory that processes your codebase file-by-file, verifies changes with tests, and handles git state automatically.

## The Toolkit

| Script | Role | Description |
| :--- | :--- | :--- |
| **orchestrator.py** | **The Worker** | Refactors a *single file* safely. Creates a git branch, runs the AI, runs tests, and commits only on success. |
| **scan\_and\_refactor.py** | **The Manager** | Scans your project, filters files (ignoring node\_modules, tests), and assigns work to the Orchestrator. |
| **propagate\_rename.py** | **The Fixer** | A "Search & Replace" utility to fix broken imports across the project after a rename refactor. |
| **orcha-run.sh** | **Easy Runner** | Simplified wrapper for running orcha with sensible defaults. |
| **orcha-status.sh** | **Monitor** | Check run status, view failures, and see recent git activity. |

-----

## Quick Start (Recommended)

The easiest way to run orcha is with the wrapper scripts:

```bash
# Navigate to your project
cd /path/to/your/project

# Run a dry-run first to see what files will be processed
/path/to/orcha/orcha-run.sh src "Add JSDoc documentation" --dry-run

# Run for real with Gemini (default model)
/path/to/orcha/orcha-run.sh src "Add JSDoc documentation"

# Run with Claude Sonnet
/path/to/orcha/orcha-run.sh src "Convert to ES6" --model s

# Run in background and monitor
/path/to/orcha/orcha-run.sh src "Modernize code" --background

# Check status
/path/to/orcha/orcha-status.sh
/path/to/orcha/orcha-status.sh --git      # Recent commits
/path/to/orcha/orcha-status.sh --failed   # Failed files
/path/to/orcha/orcha-status.sh --watch    # Live monitor
```

-----

## Installation

### Option A: Docker (Recommended)

This handles all dependencies (Python, Node/Bun, Refactor tool) for you.

1.  **Run with Docker Compose:**
    ```bash
    # Set your API keys first
    export OPENAI_API_KEY=sk-...
    export GOOGLE_API_KEY=...
    export MOONSHOT_API_KEY=...
    
    # Start the persistent container
    docker compose up -d

    # Run commands inside the container
    docker compose exec orcha orcha --help
    ```


### Option B: Local Installation

The tools are located in the root directory. You can install them as a python package for easy access.

1.  **Install the Package:**
    ```bash
    pip install .
    ```
    *Alternatively, install dependencies manually:*
    ```bash
    pip install -r requirements.txt
    ```

2.  **External Requirements:**
    *   **Node.js / Bun**: Required for running the underlying refactor tool.
    *   **Refactor Tool**: This pipeline expects `Refactor.ts` (or a similar CLI tool) to be present.
        *   *Recommendation:* [VictorTaelin/AI-scripts](https://github.com/VictorTaelin/AI-scripts)
        *   Ensure `Refactor.ts` is executable or callable via `bun Refactor.ts`.

-----

## Usage

### With Docker

Prefix commands with `docker compose run orcha`. The current directory is mounted to `/workspace`.

```bash
docker compose exec orcha orcha-scan src --instruction "Fix types" --dry-run
```

### With Local Install

Once installed, you can use the CLI commands `orcha`, `orcha-scan`, and `orcha-propagate`. If you didn't install the package, you can run the scripts directly via `python3 <script>.py`.

### Level 1: Refactor a Single File (Precision Mode)

Use this when you want to closely monitor a complex refactor on a core file.

```bash
# Syntax
orcha --file <PATH> --instruction "<PROMPT>" [--json] [--force-branch]

# Example
orcha \
  --file src/services/UserService.ts \
  --instruction "Split this class into UserService and UserRepository. Keep the interface same." \
  --test-cmd "npm test src/services/UserService.test.ts"
```

**What happens?**

1.  Checks if Git is clean.
2.  Creates branch `refactor/UserService`.
3.  Runs the AI Agent.
4.  Runs `npm test`.
5.  **Success:** Merges to main and deletes branch.
6.  **Fail:** Reverts changes, deletes branch, and logs error.

-----

### Level 2: Mass Refactor (Batch Mode)

Use this to apply "Safe Refactors" (cleanups, typing, comments) across the whole codebase.

```bash
# Syntax
orcha-scan <DIRECTORY> --instruction "<PROMPT>" [--dry-run] [--resume-from PATH] [--skip-successful]

# Example 1: Add Types
orcha-scan src \
  --instruction "Infer and add TypeScript types to all 'any' variables." \
  --ext .ts

# Example 2: Cleanup (Dry Run first!)
orcha-scan src/utils \
  --instruction "Remove console.log statements and add JSDoc to exported functions." \
  --dry-run

# Example 3: Resume after a crash
# If the script stopped at src/utils/logger.ts, resume from there:
orcha-scan src --instruction "Fix types" --resume-from src/utils/logger.ts

# Example 4: Retry only failed files
# Skips any file marked as "success" in refactor_history.jsonl
orcha-scan src --instruction "Fix types" --skip-successful
```

**History & Logs:**
The script maintains a `refactor_history.jsonl` file in the current directory. This tracks every file processed, its status (success/failure), and error summaries. This file is also used by `--resume-from` and `--skip-successful` to determine state.

**Configuration:**

  * Edit `scan_and_refactor.py` to modify `IGNORE_DIRS` (default: `node_modules`, `dist`, `.git`) or `IGNORE_FILES`.

-----

### Level 3: Structural Changes (The "Dangerous" Mode)

Use this workflow when renaming classes or functions that are imported by other files.

1.  **Refactor the Definition:**
    ```bash
    orcha --file src/auth/AuthMgr.ts --instruction "Rename class AuthMgr to AuthProvider"
    ```
2.  **Propagate the Change:**
    Run the propagator to fix the broken imports in the rest of the app.
    ```bash
    orcha-propagate --old "AuthMgr" --new "AuthProvider" --root src/
    ```
3.  **Verify:**
    ```bash
    npm test
    ```

-----

## Safety Protocols

This pipeline is designed to be **nondestructive**, but AI is unpredictable.

1.  **The "Git Latch":** The orchestrator will **refuse to run** if your git working tree is dirty. Commit or stash your work first.
2.  **The "Revert Trigger":** If `npm test` fails, the Orchestrator performs a `git reset --hard`. It does not leave broken code in your repo.
3.  **Concurrency Lock:** A `.orcha.lock` file prevents multiple orchestrator instances from running simultaneously on the same workspace.
4.  **Context Limits:** The `scan_and_refactor.py` processes files *sequentially*. It does not feed the entire codebase to the context window, saving you money and token limits.

## Customization

  * **Change the LLM:** Modify the `Refactor.ts` call in `orchestrator.py` (inside `node_run_refactor`) to point to a different model or script.
    *   **Supported Models:**
        *   `openai` (default)
        *   `anthropic`
        *   `k` (Kimi K2 - Moonshot)
        *   `i` (Gemini 1.5 Pro)
  * **Change the Test Command:** Default is `npm test`. You can override this per run or globally in the script defaults.
  * **Retry Logic:** Adjust `MAX_RETRIES` in `orchestrator.py` if you want the agent to try fixing its own errors more aggressively.

## Recipes

*   [Refactoring jQuery to ES6](recipes/jquery_to_es6.md)


## Troubleshooting

| Issue | Solution |
| :--- | :--- |
| **"Git working tree not clean"** | You have uncommitted changes. Run `git stash` before starting. |
| **Tests fail immediately** | Ensure the `--test-cmd` you passed is valid for that specific file. |
| **Refactor.ts not found** | Check the `refactor_cmd` argument in `orchestrator.py`. Ensure you have the dependency installed. |
| **Infinite Loop** | The agent might be "fixing" code back and forth. Reduce `MAX_RETRIES` to 1. |
| **"Git user not configured"** | Run `git config --global user.email ...` inside the container or mount your .gitconfig. |
| **API Key Errors** | Ensure `GOOGLE_API_KEY` or `MOONSHOT_API_KEY` are set if using those models. |