#!/usr/bin/env bash
# orcha-parallel.sh - Run orcha with multiple workers in parallel using clones
#
# Usage:
#   ./orcha-parallel.sh <target_dir> "<instruction>" <num_workers> [options]
#
# Examples:
#   ./orcha-parallel.sh src "Add JSDoc documentation" 3
#   ./orcha-parallel.sh src "Add JSDoc" 3 --model i --ext .js
#
# Each worker gets a separate clone of the repo, processes a disjoint subset
# of files, and results are merged back via per-worker remotes.
#
# IMPORTANT DIFFERENCES FROM orcha-run.sh:
#   - Requires clean working tree (no uncommitted changes)
#   - Tests are disabled by default (use --test-cmd to enable)
#   - Creates staging branch; you must manually --ff-only merge to main
#   - TARGET_DIR must be relative to repo root

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
MODEL="i"
MODELS=""
EXT=".js"
TEST_CMD=""  # Populated if user passes --test-cmd
SKIP_TESTS=true  # Default: skip tests for speed; always passes --test-cmd "true" or user value
CLONE_BASE="/tmp/orcha-clones"
ALLOW_DIRTY=false
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# Parse required arguments
if [ $# -lt 3 ]; then
    echo -e "${RED}Usage:${NC}"
    echo "  $0 <target_dir> \"<instruction>\" <num_workers> [options]"
    echo "  $0 --file <target_file> \"<instruction>\" [options]"
    echo ""
    echo "Options:"
    echo "  --model <spec>     Model to use (default: i = Gemini)"
    echo "  --file <path>      Run on a single file (bypasses scan_and_refactor.py)"
    echo "  --ext <extension>  File extension (default: .js)"
    echo "  --test-cmd <cmd>   Test command (enables testing; default: tests disabled)"
    echo "  --clone-dir <dir>  Base directory for clones (default: /tmp/orcha-clones)"
    echo "  --allow-dirty      Allow running with uncommitted changes in working tree"
    echo "  --models a,b,c     Run one clone per model (processes ALL files per model)"
    echo ""
    echo "Note: Tests are disabled by default for speed. Use --test-cmd 'npm test' to enable."
    echo ""
    echo "Examples:"
    echo "  $0 javascripts \"Add JSDoc documentation\" 3"
    echo "  $0 src \"Convert to ES6\" 4 --model s --ext .ts"
    echo "  $0 src \"Add types\" 3 --test-cmd 'npm test'"
    echo "  $0 --file src/foo.ts \"Refactor this\" --models g3f,g2 --test-cmd 'npm test'"
    exit 1
fi

MODE="dir"
TARGET_DIR=""
TARGET_FILE=""
INSTRUCTION=""
NUM_WORKERS=""

if [[ "${1:-}" = "--file" || "${1:-}" = "-f" ]]; then
    MODE="file"
    TARGET_FILE="${2:-}"
    INSTRUCTION="${3:-}"
    NUM_WORKERS="1"
    shift 3
else
    TARGET_DIR="$1"
    INSTRUCTION="$2"
    NUM_WORKERS="$3"
    shift 3
fi

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --file|-f)
            MODE="file"
            TARGET_FILE="$2"
            shift 2
            ;;
        --ext)
            EXT="$2"
            shift 2
            ;;
        --test-cmd)
            TEST_CMD="$2"
            SKIP_TESTS=false
            shift 2
            ;;
        --clone-dir)
            CLONE_BASE="$2"
            shift 2
            ;;
        --models)
            MODELS="$2"
            shift 2
            ;;
        --allow-dirty)
            ALLOW_DIRTY=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# --- VALIDATION GUARDS ---

# Get repo root and base SHA
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BASE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
ORCHA_DIR="$(dirname "$(realpath "$0")")"

# Model selection:
# - Default (no --models): NUM_WORKERS workers all use the same --model and partition files.
# - With --models: one worker per model; each worker processes ALL files.
MULTI_MODEL=false
WORKER_MODELS=()
if [ -n "$MODELS" ]; then
    MULTI_MODEL=true
    IFS=',' read -r -a WORKER_MODELS <<< "$MODELS"
    # Trim whitespace in entries
    for idx in "${!WORKER_MODELS[@]}"; do
        WORKER_MODELS[$idx]="$(echo "${WORKER_MODELS[$idx]}" | tr -d '[:space:]')"
    done
    # Drop empty model entries
    FILTERED_MODELS=()
    for m in "${WORKER_MODELS[@]}"; do
        if [ -n "$m" ]; then
            FILTERED_MODELS+=("$m")
        fi
    done
    WORKER_MODELS=("${FILTERED_MODELS[@]}")
    NUM_WORKERS="${#WORKER_MODELS[@]}"
else
    if [ "$MODE" = "file" ]; then
        NUM_WORKERS="1"
        WORKER_MODELS=("$MODEL")
    else
        # Validate NUM_WORKERS provided by user in directory mode
        if ! [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] || [ "$NUM_WORKERS" -le 0 ]; then
            echo -e "${RED}NUM_WORKERS must be a positive integer.${NC}" >&2
            exit 1
        fi
        for i in $(seq 0 $((NUM_WORKERS-1))); do
            WORKER_MODELS+=("$MODEL")
        done
    fi
fi

# Validate we have at least 1 worker
if ! [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] || [ "$NUM_WORKERS" -le 0 ]; then
    echo -e "${RED}NUM_WORKERS must be a positive integer (after model selection).${NC}" >&2
    exit 1
fi
if [ "$MULTI_MODEL" = true ] && [ "$NUM_WORKERS" -eq 0 ]; then
    echo -e "${RED}--models was provided but no valid models were parsed.${NC}" >&2
    exit 1
fi

# 2. Check for detached HEAD
if [ "$BASE_BRANCH" = "HEAD" ]; then
    echo -e "${RED}Detached HEAD not supported for orcha-parallel.${NC}" >&2
    echo "Please checkout a named branch first: git checkout <branch>" >&2
    exit 1
fi

# 3. Check for dirty working tree
if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    if [ "$ALLOW_DIRTY" = true ]; then
        echo -e "${YELLOW}Warning: Working tree is dirty. Proceeding anyway (--allow-dirty).${NC}"
    else
        echo -e "${RED}Working tree is dirty in $REPO_ROOT.${NC}" >&2
        echo "Commit or stash changes before running orcha-parallel." >&2
        echo "Use --allow-dirty to bypass this check (refactors will be based on HEAD, not working tree)." >&2
        exit 1
    fi
fi

# 4. Validate target (dir or file)
if [ "$MODE" = "file" ]; then
    if [ -z "$TARGET_FILE" ]; then
        echo -e "${RED}--file requires a path.${NC}" >&2
        exit 1
    fi
    if [[ "$TARGET_FILE" = /* ]]; then
        echo -e "${RED}TARGET_FILE must be relative to the repo root, not absolute.${NC}" >&2
        exit 1
    fi
    if [ ! -f "$REPO_ROOT/$TARGET_FILE" ]; then
        echo -e "${RED}File '$TARGET_FILE' not found under $REPO_ROOT${NC}" >&2
        exit 1
    fi
else
    if [[ "$TARGET_DIR" = /* ]]; then
        echo -e "${RED}TARGET_DIR must be relative to the repo root, not absolute.${NC}" >&2
        exit 1
    fi
    if [ ! -d "$REPO_ROOT/$TARGET_DIR" ]; then
        echo -e "${RED}Directory '$TARGET_DIR' not found under $REPO_ROOT${NC}" >&2
        exit 1
    fi
fi

# Scope clone directory by repo name to avoid collisions
REPO_NAME="$(basename "$REPO_ROOT")"
CLONE_BASE="${CLONE_BASE}/${REPO_NAME}"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}         ${GREEN}ORCHA - Parallel Clone Execution${NC}               ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Repository:${NC}  ${REPO_ROOT}"
echo -e "${YELLOW}Base SHA:${NC}    ${BASE_SHA:0:12}"
echo -e "${YELLOW}Base Branch:${NC} ${BASE_BRANCH}"
if [ "$MODE" = "file" ]; then
    echo -e "${YELLOW}Target file:${NC} ${TARGET_FILE}"
else
    echo -e "${YELLOW}Target dir:${NC}  ${TARGET_DIR}"
fi
echo -e "${YELLOW}Instruction:${NC} ${INSTRUCTION}"
echo -e "${YELLOW}Workers:${NC}     ${NUM_WORKERS}"
if [ "$MULTI_MODEL" = true ]; then
    echo -e "${YELLOW}Models:${NC}      ${WORKER_MODELS[*]}"
else
    echo -e "${YELLOW}Model:${NC}       ${MODEL}"
fi
echo -e "${YELLOW}Extension:${NC}   ${EXT}"
echo -e "${YELLOW}Tests:${NC}       $([ "$SKIP_TESTS" = true ] && echo "Disabled (use --test-cmd to enable)" || echo "$TEST_CMD")"
echo ""

# Create clone directory
mkdir -p "$CLONE_BASE"

# Cleanup old clones
echo -e "${CYAN}Cleaning up old clones...${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    MODEL_SPEC="${WORKER_MODELS[$i]}"
    rm -rf "${CLONE_BASE}/worker-${i}-${MODEL_SPEC}"
done

# Create clones with --reference for space efficiency
echo -e "${CYAN}Creating worker clones (with --reference for space efficiency)...${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    MODEL_SPEC="${WORKER_MODELS[$i]}"
    CLONE_DIR="${CLONE_BASE}/worker-${i}-${MODEL_SPEC}"
    echo -e "  [${i}] Cloning to ${CLONE_DIR} (model: ${MODEL_SPEC})..."
    git clone --reference "$REPO_ROOT" --quiet "$REPO_ROOT" "$CLONE_DIR"
    # Pin to base SHA
    git -C "$CLONE_DIR" reset --hard "$BASE_SHA" --quiet
done
echo ""

# Start workers
echo -e "${GREEN}Starting ${NUM_WORKERS} workers in parallel...${NC}"
PIDS=()
LOG_FILES=()
MODEL_SPECS=()
CLONE_DIRS=()

for i in $(seq 0 $((NUM_WORKERS-1))); do
    MODEL_SPEC="${WORKER_MODELS[$i]}"
    CLONE_DIR="${CLONE_BASE}/worker-${i}-${MODEL_SPEC}"
    LOG_FILE="${CLONE_BASE}/worker-${i}-${MODEL_SPEC}.log"
    LOG_FILES+=("$LOG_FILE")
    MODEL_SPECS+=("$MODEL_SPEC")
    CLONE_DIRS+=("$CLONE_DIR")
    
    echo -e "  ${CYAN}[Worker ${i}]${NC} Starting (model: ${MODEL_SPEC})... log: ${LOG_FILE}"
    
    (
        cd "$CLONE_DIR"
        
        # Build command
        CMD=()
        if [ "$MODE" = "file" ]; then
            CMD=(python3 "${ORCHA_DIR}/orchestrator.py"
                --file "$TARGET_FILE"
                --instruction "$INSTRUCTION"
                --model-spec "$MODEL_SPEC"
                --force-branch
            )
        else
            if [ "$MULTI_MODEL" = true ]; then
                # One worker per model; each processes ALL files
                CMD=(python3 "${ORCHA_DIR}/scan_and_refactor.py"
                    "$TARGET_DIR"
                    --instruction "$INSTRUCTION"
                    --ext "$EXT"
                    --model-spec "$MODEL_SPEC"
                    --force-branch
                    --worker 0
                    --total-workers 1
                )
            else
                # Many workers; partition files across workers (original behavior)
                CMD=(python3 "${ORCHA_DIR}/scan_and_refactor.py"
                    "$TARGET_DIR"
                    --instruction "$INSTRUCTION"
                    --ext "$EXT"
                    --model-spec "$MODEL_SPEC"
                    --force-branch
                    --worker "$i"
                    --total-workers "$NUM_WORKERS"
                )
            fi
        fi
        
        # Add test command if specified, otherwise use 'true' to skip
        if [ "$SKIP_TESTS" = true ]; then
            CMD+=(--test-cmd "true")
        elif [ -n "$TEST_CMD" ]; then
            CMD+=(--test-cmd "$TEST_CMD")
        fi
        # Note: --skip-git-check NOT passed; clones are clean so check should pass
        
        "${CMD[@]}" > "$LOG_FILE" 2>&1
    ) &
    PIDS+=($!)
done

echo ""
echo -e "${YELLOW}Workers running. Monitor progress with:${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    echo "  tail -f ${LOG_FILES[$i]}"
done
echo ""

# Wait for all workers
echo -e "${CYAN}Waiting for all workers to complete...${NC}"
FAILED_WORKERS=()
for i in $(seq 0 $((NUM_WORKERS-1))); do
    if ! wait "${PIDS[$i]}"; then
        FAILED_WORKERS+=("$i")
        echo -e "  ${RED}[Worker ${i}] FAILED${NC}"
    else
        echo -e "  ${GREEN}[Worker ${i}] COMPLETED${NC}"
    fi
done

echo ""

# Check for failures
if [ ${#FAILED_WORKERS[@]} -gt 0 ]; then
    echo -e "${RED}Some workers failed: ${FAILED_WORKERS[*]}${NC}"
    echo "Check logs for details. Proceeding with merge of successful workers..."
fi

echo ""

# Merge results back
if [ "$MULTI_MODEL" = true ]; then
    echo -e "${CYAN}Merging results back to ${REPO_ROOT} (one staging branch per model)...${NC}"
    echo ""

    MERGE_FAILED=()
    STAGING_BRANCHES=()

    for i in $(seq 0 $((NUM_WORKERS-1))); do
        # Skip failed workers
        if [[ " ${FAILED_WORKERS[*]} " =~ " ${i} " ]]; then
            echo -e "  ${YELLOW}[Worker ${i}] Skipped (failed)${NC}"
            continue
        fi

        MODEL_SPEC="${MODEL_SPECS[$i]}"
        CLONE_DIR="${CLONE_DIRS[$i]}"
        REMOTE_NAME="orcha-worker-${i}-${MODEL_SPEC}"

        # Check if worker made any commits
        WORKER_COMMITS=$(git -C "$CLONE_DIR" rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo "0")
        if [ "$WORKER_COMMITS" = "0" ]; then
            echo -e "  ${YELLOW}[Worker ${i}] No commits to merge (model: ${MODEL_SPEC})${NC}"
            continue
        fi

        STAGING_BRANCH="orcha-merged-${MODEL_SPEC}-${TIMESTAMP}"
        echo -e "  ${CYAN}[Worker ${i}] Merging ${WORKER_COMMITS} commits to ${STAGING_BRANCH}...${NC}"

        git -C "$REPO_ROOT" checkout -B "$STAGING_BRANCH" "$BASE_SHA"

        # Add worker clone as remote
        git -C "$REPO_ROOT" remote remove "$REMOTE_NAME" 2>/dev/null || true
        git -C "$REPO_ROOT" remote add "$REMOTE_NAME" "$CLONE_DIR"

        # Fetch and merge
        git -C "$REPO_ROOT" fetch "$REMOTE_NAME" "$BASE_BRANCH" --quiet
        if git -C "$REPO_ROOT" merge --no-ff FETCH_HEAD -m "Merge worker-${i} (${MODEL_SPEC}) refactors" --quiet; then
            echo -e "    ${GREEN}✓ Merged successfully into ${STAGING_BRANCH}${NC}"
            STAGING_BRANCHES+=("$STAGING_BRANCH")
        else
            echo -e "    ${RED}✗ Merge conflict in ${STAGING_BRANCH} - needs manual resolution${NC}"
            MERGE_FAILED+=("$i")
            git -C "$REPO_ROOT" merge --abort || true
        fi

        # Cleanup remote
        git -C "$REPO_ROOT" remote remove "$REMOTE_NAME"
    done

    echo ""

    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                    ${GREEN}MERGE COMPLETE${NC}                       ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Failed workers:${NC} ${#FAILED_WORKERS[@]}"
    echo -e "${YELLOW}Merge conflicts:${NC} ${#MERGE_FAILED[@]}"
    if [ ${#STAGING_BRANCHES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Staging branches:${NC}"
        for b in "${STAGING_BRANCHES[@]}"; do
            echo "  $b"
        done
        echo ""
        echo "To inspect:"
        for b in "${STAGING_BRANCHES[@]}"; do
            echo "  git log ${BASE_SHA}..${b} --oneline"
        done
        echo ""
        echo "To finalize (pick the model you want):"
        for b in "${STAGING_BRANCHES[@]}"; do
            echo "  git checkout ${BASE_BRANCH} && git merge --ff-only ${b}"
        done
    else
        echo -e "${YELLOW}No commits were merged. Check worker logs for issues.${NC}"
    fi
else
    echo -e "${CYAN}Merging results back to ${REPO_ROOT}...${NC}"
    echo ""

    # Create staging branch
    STAGING_BRANCH="orcha-merged-${TIMESTAMP}"
    git -C "$REPO_ROOT" checkout -B "$STAGING_BRANCH" "$BASE_SHA"

    MERGE_FAILED=()
    for i in $(seq 0 $((NUM_WORKERS-1))); do
        MODEL_SPEC="${MODEL_SPECS[$i]}"
        CLONE_DIR="${CLONE_DIRS[$i]}"
        REMOTE_NAME="orcha-worker-${i}-${MODEL_SPEC}"

        # Skip failed workers
        if [[ " ${FAILED_WORKERS[*]} " =~ " ${i} " ]]; then
            echo -e "  ${YELLOW}[Worker ${i}] Skipped (failed)${NC}"
            continue
        fi

        # Check if worker made any commits
        WORKER_COMMITS=$(git -C "$CLONE_DIR" rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo "0")
        if [ "$WORKER_COMMITS" = "0" ]; then
            echo -e "  ${YELLOW}[Worker ${i}] No commits to merge${NC}"
            continue
        fi

        echo -e "  ${CYAN}[Worker ${i}] Merging ${WORKER_COMMITS} commits...${NC}"

        # Add worker clone as remote
        git -C "$REPO_ROOT" remote remove "$REMOTE_NAME" 2>/dev/null || true
        git -C "$REPO_ROOT" remote add "$REMOTE_NAME" "$CLONE_DIR"

        # Fetch and merge
        git -C "$REPO_ROOT" fetch "$REMOTE_NAME" "$BASE_BRANCH" --quiet
        if git -C "$REPO_ROOT" merge --no-ff FETCH_HEAD -m "Merge worker-${i} refactors" --quiet; then
            echo -e "    ${GREEN}✓ Merged successfully${NC}"
        else
            echo -e "    ${RED}✗ Merge conflict - needs manual resolution${NC}"
            MERGE_FAILED+=("$i")
            git -C "$REPO_ROOT" merge --abort || true
        fi

        # Cleanup remote
        git -C "$REPO_ROOT" remote remove "$REMOTE_NAME"
    done

    echo ""

    TOTAL_COMMITS=$(git -C "$REPO_ROOT" rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo "0")

    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                    ${GREEN}MERGE COMPLETE${NC}                       ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Staging branch:${NC} ${STAGING_BRANCH}"
    echo -e "${YELLOW}Total commits:${NC}  ${TOTAL_COMMITS}"
    echo -e "${YELLOW}Failed workers:${NC} ${#FAILED_WORKERS[@]}"
    echo -e "${YELLOW}Merge conflicts:${NC} ${#MERGE_FAILED[@]}"
    echo ""

    if [ ${#MERGE_FAILED[@]} -gt 0 ]; then
        echo -e "${RED}Some merges failed. Resolve conflicts manually on branch: ${STAGING_BRANCH}${NC}"
    elif [ "$TOTAL_COMMITS" -gt 0 ]; then
        echo -e "${GREEN}All merges successful!${NC}"
        echo ""
        echo "To finalize, run:"
        echo -e "  ${CYAN}git checkout ${BASE_BRANCH}${NC}"
        echo -e "  ${CYAN}git merge --ff-only ${STAGING_BRANCH}${NC}"
        echo ""
        echo "Or to inspect first:"
        echo -e "  ${CYAN}git log ${BASE_SHA}..${STAGING_BRANCH} --oneline${NC}"
    else
        echo -e "${YELLOW}No commits were made. Check worker logs for issues.${NC}"
    fi
fi

echo ""
echo -e "${CYAN}Cleanup clones with: rm -rf ${CLONE_BASE}${NC}"
echo -e "${CYAN}Or cleanup all repos: rm -rf /tmp/orcha-clones${NC}"
