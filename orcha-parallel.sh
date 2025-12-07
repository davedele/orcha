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
EXT=".js"
TEST_CMD="true"
CLONE_BASE="/tmp/orcha-clones"

# Parse required arguments
if [ $# -lt 3 ]; then
    echo -e "${RED}Usage: $0 <target_dir> \"<instruction>\" <num_workers> [options]${NC}"
    echo ""
    echo "Options:"
    echo "  --model <spec>     Model to use (default: i = Gemini)"
    echo "  --ext <extension>  File extension (default: .js)"
    echo "  --test-cmd <cmd>   Test command (default: 'true')"
    echo "  --clone-dir <dir>  Base directory for clones (default: /tmp/orcha-clones)"
    echo ""
    echo "Examples:"
    echo "  $0 javascripts \"Add JSDoc documentation\" 3"
    echo "  $0 src \"Convert to ES6\" 4 --model s --ext .ts"
    exit 1
fi

TARGET_DIR="$1"
INSTRUCTION="$2"
NUM_WORKERS="$3"
shift 3

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --ext)
            EXT="$2"
            shift 2
            ;;
        --test-cmd)
            TEST_CMD="$2"
            shift 2
            ;;
        --clone-dir)
            CLONE_BASE="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Get repo root and base SHA
REPO_ROOT="$(git rev-parse --show-toplevel)"
BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BASE_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
ORCHA_DIR="$(dirname "$(realpath "$0")")"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}         ${GREEN}ORCHA - Parallel Clone Execution${NC}               ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Repository:${NC}  ${REPO_ROOT}"
echo -e "${YELLOW}Base SHA:${NC}    ${BASE_SHA:0:12}"
echo -e "${YELLOW}Base Branch:${NC} ${BASE_BRANCH}"
echo -e "${YELLOW}Target:${NC}      ${TARGET_DIR}"
echo -e "${YELLOW}Instruction:${NC} ${INSTRUCTION}"
echo -e "${YELLOW}Workers:${NC}     ${NUM_WORKERS}"
echo -e "${YELLOW}Model:${NC}       ${MODEL}"
echo -e "${YELLOW}Extension:${NC}   ${EXT}"
echo ""

# Create clone directory
mkdir -p "$CLONE_BASE"

# Cleanup old clones
echo -e "${CYAN}Cleaning up old clones...${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    rm -rf "${CLONE_BASE}/worker-${i}"
done

# Create clones with --reference for space efficiency
echo -e "${CYAN}Creating worker clones (with --reference for space efficiency)...${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    CLONE_DIR="${CLONE_BASE}/worker-${i}"
    echo -e "  [${i}] Cloning to ${CLONE_DIR}..."
    git clone --reference "$REPO_ROOT" --quiet "$REPO_ROOT" "$CLONE_DIR"
    # Pin to base SHA
    git -C "$CLONE_DIR" reset --hard "$BASE_SHA" --quiet
    # Copy orcha scripts (they're not in the repo being refactored)
    # Note: orcha scripts are expected to be in a separate location
done
echo ""

# Start workers
echo -e "${GREEN}Starting ${NUM_WORKERS} workers in parallel...${NC}"
PIDS=()
LOG_FILES=()

for i in $(seq 0 $((NUM_WORKERS-1))); do
    CLONE_DIR="${CLONE_BASE}/worker-${i}"
    LOG_FILE="${CLONE_BASE}/worker-${i}.log"
    LOG_FILES+=("$LOG_FILE")
    
    echo -e "  ${CYAN}[Worker ${i}]${NC} Starting... log: ${LOG_FILE}"
    
    (
        cd "$CLONE_DIR"
        python3 "${ORCHA_DIR}/scan_and_refactor.py" \
            "$TARGET_DIR" \
            --instruction "$INSTRUCTION" \
            --ext "$EXT" \
            --model-spec "$MODEL" \
            --test-cmd "$TEST_CMD" \
            --skip-git-check \
            --force-branch \
            --worker "$i" \
            --total-workers "$NUM_WORKERS" \
            > "$LOG_FILE" 2>&1
    ) &
    PIDS+=($!)
done

echo ""
echo -e "${YELLOW}Workers running. Monitor progress with:${NC}"
for i in $(seq 0 $((NUM_WORKERS-1))); do
    echo "  tail -f ${CLONE_BASE}/worker-${i}.log"
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

# Merge results back
echo -e "${CYAN}Merging results back to ${REPO_ROOT}...${NC}"
echo ""

# Create staging branch
STAGING_BRANCH="orcha-merged-$(date +%Y%m%d-%H%M%S)"
git -C "$REPO_ROOT" checkout -B "$STAGING_BRANCH" "$BASE_SHA"

MERGE_FAILED=()
for i in $(seq 0 $((NUM_WORKERS-1))); do
    CLONE_DIR="${CLONE_BASE}/worker-${i}"
    REMOTE_NAME="orcha-worker-${i}"
    
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

# Summary
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

echo ""
echo -e "${CYAN}Cleanup clones with: rm -rf ${CLONE_BASE}${NC}"
