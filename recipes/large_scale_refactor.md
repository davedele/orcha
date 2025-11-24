# Workflow: Large Scale Legacy Refactor (jQuery/JS/HTML/CSS)

Refactoring a large legacy codebase is a marathon, not a sprint. This workflow breaks the process down into safe, manageable phases using `orcha`.

## Prerequisites

1.  **Version Control**: Ensure the repo is git-initialized.
2.  **Baseline Tests**: You need *some* way to verify things aren't broken. If you have no tests, your first step is to add a basic "smoke test" (e.g., does the page load? do console errors appear?).
3.  **Backups**: `orcha` handles git branches, but having a clean `main` branch is critical.

---

## Phase 1: The "Low Hanging Fruit" (Sanitization)

**Goal**: Clean up the code without changing behavior. This reduces noise for later, more complex steps.

### 1.1 Add JSDoc & Comments
Before changing code, ask AI to understand it. This adds documentation that will help the AI (and you) in later steps.

```bash
orcha-scan src/js \
  --ext .js \
  --instruction "Analyze this code. Add JSDoc comments to all functions explaining their inputs, outputs, and purpose. Do NOT change any logic." \
  --model-spec k
```

### 1.2 Modernize Syntax (Safe)
Convert `var` to `const/let` and fix formatting. This usually doesn't break logic but makes the code readable.

```bash
orcha-scan src/js \
  --ext .js \
  --instruction "Convert 'var' to 'const' or 'let' where appropriate. Use template literals for string concatenation. Do NOT remove jQuery yet." \
  --test-cmd "npm test"
```

---

## Phase 2: De-jQuery (The Heavy Lifting)

**Goal**: Remove the dependency on jQuery to prepare for modern frameworks or lighter vanilla JS.

### 2.1 Replace AJAX with Fetch
Network calls are isolated and easy to verify.

```bash
orcha-scan src/js \
  --ext .js \
  --instruction "Replace $.ajax, $.get, and $.post with modern 'fetch' and async/await. Ensure error handling is preserved." \
  --test-cmd "npm test"
```

### 2.2 Replace Utilities
Replace `$.each`, `$.map`, `$.extend` with native JS methods.

```bash
orcha-scan src/js \
  --ext .js \
  --instruction "Replace jQuery utility functions ($.each, $.map, $.extend) with native JavaScript equivalents (forEach, map, Object.assign/spread). Do NOT touch DOM selectors yet." \
  --test-cmd "npm test"
```

### 2.3 DOM Selectors (The Risky Part)
This is where things often break because jQuery handles nulls gracefully (e.g., `$('.missing').hide()` does nothing) while Vanilla JS crashes (`document.querySelector('.missing').style.display = 'none'` throws error).

**Instruction must emphasize safety:**

```bash
orcha-scan src/js \
  --ext .js \
  --instruction "Refactor DOM manipulation to use 'document.querySelector' and 'addEventListener'. IMPORTANT: Add null checks! If an element might not exist, check if it is null before accessing properties." \
  --test-cmd "npm test"
```

---

## Phase 3: Modularization (Architecture)

**Goal**: Stop using global variables and `<script>` tag soup. Move to ES Modules.

### 3.1 Extract Logic to Modules
If you have huge files (e.g., `app.js` is 5000 lines), use `orcha` to split them.

*Note: This is best done file-by-file using `orcha --file` rather than scanning.*

```bash
orcha --file src/js/huge-controller.js \
  --instruction "Extract the user authentication logic into a separate class or module. Keep the rest of the file as is."
```

---

## Phase 4: CSS Modernization

**Goal**: Move from global CSS to scoped or utility-based CSS.

### 4.1 Fix Naming Conventions
```bash
orcha-scan src/css \
  --ext .css \
  --instruction "Refactor CSS class names to follow BEM convention (Block Element Modifier) where obvious. Update the corresponding HTML files if possible (requires multi-file context, advanced usage)."
```

*Note: Updating CSS and HTML simultaneously is tricky. It's often better to just clean up the CSS file structure first.*

---

## Tips for Success

1.  **Small Batches**: Don't run `orcha-scan` on the entire folder at once if it's huge. Do `src/js/utils` first, then `src/js/components`.
2.  **Review Diffs**: Use the `--dry-run` flag to see what the AI is planning before committing.
3.  **Locking**: If you have a team, ensure `.orcha.lock` is respected so you don't overwrite each other's refactors.
