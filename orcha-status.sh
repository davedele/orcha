#!/bin/bash
# orcha-status.sh - Check status of orcha runs
#
# Usage:
#   ./orcha-status.sh              # Show summary of current/recent runs
#   ./orcha-status.sh --watch      # Live monitor current run
#   ./orcha-status.sh --failed     # Show failed files with errors
#   ./orcha-status.sh --git        # Show recent git commits from orcha

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ORCHA_DIR="/Users/m3pmx/Developer/orcha"
HISTORY_FILE=$(find . -name "refactor_history.jsonl" -type f 2>/dev/null | head -1)

show_summary() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}               ${GREEN}ORCHA Run Status${NC}                          ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check for running orcha process in Docker
    cd "$ORCHA_DIR"
    RUNNING=$(docker compose exec orcha sh -c "pgrep -f 'scan_and_refactor' || true" 2>/dev/null | tr -d '\r')
    
    if [ -n "$RUNNING" ]; then
        echo -e "${GREEN}● RUNNING${NC} - Orcha is currently processing files"
    else
        echo -e "${YELLOW}○ IDLE${NC} - No orcha process running"
    fi
    echo ""
    
    # Find history files
    echo -e "${CYAN}History Files Found:${NC}"
    find /Users/m3pmx/Developer -name "refactor_history.jsonl" -type f 2>/dev/null | while read f; do
        COUNT=$(wc -l < "$f" | tr -d ' ')
        SUCCESS=$(grep -c '"status": "success"' "$f" 2>/dev/null || echo 0)
        FAIL=$((COUNT - SUCCESS))
        echo -e "  ${f}: ${GREEN}${SUCCESS} success${NC} / ${RED}${FAIL} fail${NC} (${COUNT} total)"
    done
    echo ""
    
    # Recent log files
    echo -e "${CYAN}Recent Log Files:${NC}"
    find /Users/m3pmx/Developer -name "orcha*.log" -type f -mmin -60 2>/dev/null | head -5 | while read f; do
        SIZE=$(wc -c < "$f" | tr -d ' ')
        MTIME=$(stat -f "%Sm" -t "%H:%M" "$f")
        echo -e "  ${f} (${SIZE} bytes, ${MTIME})"
    done
    echo ""
    
    # Recent git commits
    echo -e "${CYAN}Recent AI Refactor Commits:${NC}"
    git log --oneline --since="1 day ago" --grep="AI refactor" 2>/dev/null | head -10 | while read line; do
        echo -e "  ${line}"
    done
}

show_watch() {
    echo -e "${BLUE}Watching orcha status (Ctrl+C to exit)...${NC}"
    echo ""
    
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}          ${GREEN}ORCHA Live Monitor${NC}  $(date +%H:%M:%S)                ${BLUE}║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # Find most recent history file
        HISTORY=$(find /Users/m3pmx/Developer -name "refactor_history.jsonl" -type f -mmin -60 2>/dev/null | head -1)
        
        if [ -n "$HISTORY" ]; then
            TOTAL=$(wc -l < "$HISTORY" | tr -d ' ')
            SUCCESS=$(grep -c '"status": "success"' "$HISTORY" 2>/dev/null || echo 0)
            FAIL=$((TOTAL - SUCCESS))
            
            echo -e "${CYAN}Progress:${NC} ${TOTAL} files processed"
            echo -e "  ${GREEN}✓ Success:${NC} ${SUCCESS}"
            echo -e "  ${RED}✗ Failed:${NC}  ${FAIL}"
            echo ""
            echo -e "${CYAN}Last 5 Entries:${NC}"
            tail -5 "$HISTORY" | while read line; do
                PATH_VAL=$(echo "$line" | grep -o '"path": "[^"]*"' | cut -d'"' -f4)
                STATUS=$(echo "$line" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
                if [ "$STATUS" = "success" ]; then
                    echo -e "  ${GREEN}✓${NC} ${PATH_VAL}"
                else
                    echo -e "  ${RED}✗${NC} ${PATH_VAL}"
                fi
            done
        else
            echo "No recent history file found."
        fi
        
        echo ""
        echo -e "${CYAN}Recent Git Activity:${NC}"
        git log --oneline -5 --since="1 hour ago" 2>/dev/null | head -5 || echo "  (no recent commits)"
        
        sleep 3
    done
}

show_failed() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}               ${RED}Failed Refactors${NC}                           ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Find all history files and extract failures
    find /Users/m3pmx/Developer -name "refactor_history.jsonl" -type f 2>/dev/null | while read f; do
        echo -e "${CYAN}From: ${f}${NC}"
        grep '"status": "failure"' "$f" 2>/dev/null | while read line; do
            PATH_VAL=$(echo "$line" | grep -o '"path": "[^"]*"' | cut -d'"' -f4)
            ERROR=$(echo "$line" | grep -o '"error_summary": "[^"]*"' | cut -d'"' -f4 | head -c 80)
            echo -e "  ${RED}✗${NC} ${PATH_VAL}"
            if [ -n "$ERROR" ]; then
                echo -e "    ${YELLOW}→ ${ERROR}${NC}"
            fi
        done
        echo ""
    done
}

show_git() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}            ${GREEN}Recent AI Refactor Commits${NC}                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    git log --oneline --since="7 days ago" --grep="AI refactor" | head -50 | while read line; do
        echo -e "  ${line}"
    done
    
    echo ""
    TOTAL=$(git log --oneline --since="7 days ago" --grep="AI refactor" | wc -l | tr -d ' ')
    echo -e "${CYAN}Total commits (last 7 days):${NC} ${TOTAL}"
}

# Parse arguments
case "${1:-}" in
    --watch|-w)
        show_watch
        ;;
    --failed|-f)
        show_failed
        ;;
    --git|-g)
        show_git
        ;;
    --help|-h)
        echo "Usage: $0 [option]"
        echo ""
        echo "Options:"
        echo "  (none)      Show summary of current/recent runs"
        echo "  --watch     Live monitor current run"
        echo "  --failed    Show failed files with error summaries"
        echo "  --git       Show recent git commits from orcha"
        echo "  --help      Show this help"
        ;;
    *)
        show_summary
        ;;
esac
