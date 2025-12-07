#!/bin/bash
# orcha-run.sh - Simplified wrapper for running orcha in Docker
# 
# Usage:
#   ./orcha-run.sh <target_dir> "<instruction>" [options]
#
# Examples:
#   ./orcha-run.sh javascripts "Add JSDoc documentation"
#   ./orcha-run.sh javascripts "Add JSDoc documentation" --dry-run
#   ./orcha-run.sh src "Convert to ES6" --model i --background

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
MODEL="i"  # Gemini by default (fast, good quality, cheap)
MULTI_MODEL=false
MULTI_MODELS="g,s,i"  # GPT, Claude Sonnet, Gemini
EXT=".js"
TEST_CMD="true"
BACKGROUND=false
DRY_RUN=false
SKIP_GIT_CHECK=true
FORCE_BRANCH=true

# Orcha directory (where docker-compose.yml lives)
ORCHA_DIR="/Users/m3pmx/Developer/orcha"

# Parse arguments
if [ $# -lt 2 ]; then
    echo -e "${RED}Usage: $0 <target_dir> \"<instruction>\" [options]${NC}"
    echo ""
    echo "Options:"
    echo "  --model <spec>     Model to use (default: i = Gemini)"
    echo "                     Available: g (GPT-5.1), s (Claude Sonnet), o (Claude Opus),"
    echo "                                i (Gemini 3 Pro), k (Kimi K2), q (Qwen)"
    echo "  --multi-model      Run with multiple models concurrently (g,s,i)"
    echo "  --ext <extension>  File extension (default: .js)"
    echo "  --test-cmd <cmd>   Test command (default: 'true' - skip tests)"
    echo "  --background       Run in background and tail logs"
    echo "  --dry-run          Scan files but don't refactor"
    echo "  --no-skip-git      Require clean git state"
    echo "  --no-force-branch  Don't force delete existing branches"
    echo ""
    echo "Examples:"
    echo "  $0 javascripts \"Add JSDoc comments\"                    # Uses Gemini (default)"
    echo "  $0 src \"Convert to ES6\" --model s                     # Uses Claude Sonnet"
    echo "  $0 src \"Modernize code\" --multi-model                 # Uses GPT, Claude, Gemini concurrently"
    echo "  $0 . \"Add types\" --background                         # Background with log tailing"
    exit 1
fi

TARGET_DIR="$1"
INSTRUCTION="$2"
shift 2

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --multi-model)
            MULTI_MODEL=true
            if [[ "$2" != "" && "$2" != --* ]]; then
                MULTI_MODELS="$2"
                shift
            fi
            shift
            ;;
        --ext)
            EXT="$2"
            shift 2
            ;;
        --test-cmd)
            TEST_CMD="$2"
            shift 2
            ;;
        --background)
            BACKGROUND=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-skip-git)
            SKIP_GIT_CHECK=false
            shift
            ;;
        --no-force-branch)
            FORCE_BRANCH=false
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Get the current working directory relative to workspace
CURRENT_DIR=$(pwd)
WORKSPACE_ROOT="/workspace"

# Convert local path to Docker workspace path
# Assumes we're running from somewhere under /Users/m3pmx/Developer/
RELATIVE_PATH=${CURRENT_DIR#/Users/m3pmx/Developer/}
DOCKER_CWD="${WORKSPACE_ROOT}/${RELATIVE_PATH}"

# Full target path in Docker
if [[ "$TARGET_DIR" = /* ]]; then
    # Absolute path provided
    DOCKER_TARGET="${TARGET_DIR#/Users/m3pmx/Developer/}"
    DOCKER_TARGET="${WORKSPACE_ROOT}/${DOCKER_TARGET}"
else
    # Relative path
    DOCKER_TARGET="${DOCKER_CWD}/${TARGET_DIR}"
fi

# Log file location
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${DOCKER_CWD}/orcha_${TIMESTAMP}.log"
LOCAL_LOG="${CURRENT_DIR}/orcha_${TIMESTAMP}.log"

# Build the orcha-scan command
CMD="python3 /workspace/orcha/scan_and_refactor.py"
CMD="$CMD ${DOCKER_TARGET}"
CMD="$CMD --instruction '${INSTRUCTION}'"
CMD="$CMD --ext ${EXT}"
CMD="$CMD --model-spec ${MODEL}"
CMD="$CMD --test-cmd '${TEST_CMD}'"

if [ "$SKIP_GIT_CHECK" = true ]; then
    CMD="$CMD --skip-git-check"
fi

if [ "$FORCE_BRANCH" = true ]; then
    CMD="$CMD --force-branch"
fi

if [ "$DRY_RUN" = true ]; then
    CMD="$CMD --dry-run"
fi

# Print summary
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}             ${GREEN}ORCHA - AI Refactoring Pipeline${NC}              ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Target:${NC}      ${DOCKER_TARGET}"
echo -e "${YELLOW}Instruction:${NC} ${INSTRUCTION}"
if [ "$MULTI_MODEL" = true ]; then
    echo -e "${YELLOW}Models:${NC}      ${MULTI_MODELS} (concurrent mode)"
else
    echo -e "${YELLOW}Model:${NC}       ${MODEL} ($(case $MODEL in g) echo "GPT-5.1";; s) echo "Claude Sonnet";; o) echo "Claude Opus";; i) echo "Gemini 3 Pro";; k) echo "Kimi K2";; q) echo "Qwen";; *) echo "$MODEL";; esac))"
fi
echo -e "${YELLOW}Extension:${NC}   ${EXT}"
echo -e "${YELLOW}Mode:${NC}        $([ "$DRY_RUN" = true ] && echo "Dry Run" || echo "Live")"
echo -e "${YELLOW}Background:${NC}  $([ "$BACKGROUND" = true ] && echo "Yes" || echo "No")"
echo ""

# Change to orcha directory for docker-compose
cd "$ORCHA_DIR"

# Ensure container is running
if ! docker compose ps | grep -q "orcha.*Up"; then
    echo -e "${YELLOW}Starting orcha container...${NC}"
    docker compose up -d
    sleep 2
fi

# Multi-model concurrent mode
if [ "$MULTI_MODEL" = true ]; then
    echo -e "${GREEN}Starting multi-model concurrent mode...${NC}"
    echo -e "${YELLOW}Note: Each model will process the files independently.${NC}"
    echo -e "${YELLOW}This is useful for comparing model outputs or parallel processing.${NC}"
    echo ""
    
    # Split models by comma
    IFS=',' read -ra MODEL_ARRAY <<< "$MULTI_MODELS"
    PIDS=()
    
    for m in "${MODEL_ARRAY[@]}"; do
        m=$(echo "$m" | tr -d ' ')  # Trim whitespace
        MODEL_NAME=$(case $m in g) echo "GPT-5.1";; s) echo "Claude Sonnet";; o) echo "Claude Opus";; i) echo "Gemini 3 Pro";; k) echo "Kimi K2";; q) echo "Qwen";; *) echo "$m";; esac)
        MODEL_LOG="${CURRENT_DIR}/orcha_${TIMESTAMP}_${m}.log"
        DOCKER_LOG="${DOCKER_CWD}/orcha_${TIMESTAMP}_${m}.log"
        
        # Build command for this model
        MODEL_CMD="python3 /workspace/orcha/scan_and_refactor.py"
        MODEL_CMD="$MODEL_CMD ${DOCKER_TARGET}"
        MODEL_CMD="$MODEL_CMD --instruction '${INSTRUCTION}'"
        MODEL_CMD="$MODEL_CMD --ext ${EXT}"
        MODEL_CMD="$MODEL_CMD --model-spec ${m}"
        MODEL_CMD="$MODEL_CMD --test-cmd '${TEST_CMD}'"
        [ "$SKIP_GIT_CHECK" = true ] && MODEL_CMD="$MODEL_CMD --skip-git-check"
        [ "$FORCE_BRANCH" = true ] && MODEL_CMD="$MODEL_CMD --force-branch"
        [ "$DRY_RUN" = true ] && MODEL_CMD="$MODEL_CMD --dry-run"
        
        echo -e "  ${CYAN}[${m}]${NC} Starting ${MODEL_NAME}... → ${MODEL_LOG}"
        docker compose exec -d orcha sh -c "${MODEL_CMD} > ${DOCKER_LOG} 2>&1"
        touch "$MODEL_LOG"
    done
    
    echo ""
    echo -e "${GREEN}All models started!${NC}"
    echo -e "${YELLOW}Monitor with:${NC}"
    for m in "${MODEL_ARRAY[@]}"; do
        m=$(echo "$m" | tr -d ' ')
        echo "  tail -f orcha_${TIMESTAMP}_${m}.log"
    done
    echo ""
    echo -e "${BLUE}Or use: ./orcha-status.sh --watch${NC}"
    exit 0
fi

# Single model mode
if [ "$BACKGROUND" = true ]; then
    echo -e "${GREEN}Starting in background...${NC}"
    echo -e "${YELLOW}Log file:${NC} ${LOCAL_LOG}"
    echo ""
    
    # Run in background with logging
    docker compose exec -d orcha sh -c "${CMD} > ${LOG_FILE} 2>&1"
    
    # Touch local log so it exists
    touch "${LOCAL_LOG}"
    
    echo -e "${BLUE}Tailing log (Ctrl+C to stop watching, process continues)...${NC}"
    echo ""
    
    # Tail the log
    tail -f "${LOCAL_LOG}"
else
    echo -e "${GREEN}Running in foreground...${NC}"
    echo ""
    
    # Run interactively
    docker compose exec orcha sh -c "${CMD}"
fi

