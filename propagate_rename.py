#!/usr/bin/env python3
"""
Token-aware global rename helper.

Safer than raw substring replacement for identifiers in TS/JS:
- Only replaces occurrences where the old name appears as a standalone identifier.
- Identifier charset: [A-Za-z0-9_$]
- Example:
    old="AuthService", new="UserService"

    // GOOD:
    import { AuthService } from "./service";
    new AuthService()

    // BAD (will NOT be touched):
    "Authorization header"

Caveats:
- For JSON/Markdown/text files (enabled via --include-text), this tool uses a safer regex approach than raw .replace(),
  but it still treats the old name as an identifier-like token.
- However, be aware that renaming inside URLs, IDs, or other non-code structures in these files might still occur
  if they match the identifier pattern. Always check the diff!
"""

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Iterable, Tuple

CODE_EXTS = {".ts", ".tsx", ".js", ".jsx"}
TEXT_EXTS = {".json", ".md", ".txt"}
from config import IGNORE_DIRS


def iter_files(root: Path, include_exts) -> Iterable[Path]:
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part in IGNORE_DIRS for part in p.parts):
            continue
        if p.suffix in include_exts:
            yield p


def compile_identifier_pattern(old: str) -> re.Pattern:
    # Identifier chars: letters, digits, $, _
    # Ensure we only match when old is not part of a larger identifier.
    return re.compile(
        r"(?<![A-Za-z0-9_$])" + re.escape(old) + r"(?![A-Za-z0-9_$])"
    )


def apply_rename_in_code(content: str, old: str, new: str) -> Tuple[str, int]:
    pattern = compile_identifier_pattern(old)
    return pattern.subn(new, content)


def apply_rename_in_text(content: str, old: str, new: str) -> Tuple[str, int]:
    """
    For JSON/MD/etc, still be conservative and treat as identifier-like.
    This avoids trashing words like 'Authorization' when old='Auth'.

    WARNING: This can still rename inside URLs or IDs if they look like standalone identifiers.
    """
    return apply_rename_in_code(content, old, new)


def rename_in_file(path: Path, old: str, new: str, dry_run: bool) -> int:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        # Binary or weird encoding; skip
        return 0

    if path.suffix in CODE_EXTS:
        new_text, count = apply_rename_in_code(text, old, new)
    else:
        new_text, count = apply_rename_in_text(text, old, new)

    if count > 0 and not dry_run:
        path.write_text(new_text, encoding="utf-8")

    return count


def main():
    parser = argparse.ArgumentParser(
        description="Token-aware global rename for TS/JS + related text files."
    )
    parser.add_argument(
        "root",
        help="Project root to search under (e.g., src or .)",
    )
    parser.add_argument(
        "--old",
        required=True,
        help="Old identifier/symbol name to replace.",
    )
    parser.add_argument(
        "--new",
        required=True,
        help="New identifier/symbol name.",
    )
    parser.add_argument(
        "--include-text",
        action="store_true",
        help="Also rename in JSON/Markdown/text files (default: only code files).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report changes but do not modify files.",
    )

    args = parser.parse_args()
    root = Path(args.root).resolve()
    if not root.exists():
        print(f"Root path does not exist: {root}", file=sys.stderr)
        sys.exit(1)

    include_exts = set(CODE_EXTS)
    if args.include_text:
        include_exts |= TEXT_EXTS

    total_files = 0
    total_replacements = 0

    print(f"Scanning under: {root}")
    print(f"Old -> New: {args.old!r} -> {args.new!r}")
    print(f"Dry run: {args.dry_run}")
    print(f"Extensions: {sorted(include_exts)}")

    for path in iter_files(root, include_exts):
        count = rename_in_file(path, args.old, args.new, args.dry_run)
        if count > 0:
            total_files += 1
            total_replacements += count
            print(f"[{count:3d}] {path.relative_to(root)}")

    print("\n=== Summary ===")
    print(f"Files changed:      {total_files}")
    print(f"Total replacements: {total_replacements}")
    if args.dry_run:
        print("No files were modified (dry-run).")


if __name__ == "__main__":
    main()