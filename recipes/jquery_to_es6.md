# Recipe: Refactoring jQuery to ES6+

This recipe guides you through modernizing a legacy codebase by replacing jQuery with standard ES6+ JavaScript, leveraging modules, async/await, and native array methods.

## 1. The Strategy

Refactoring is most effective when done in layers:

1.  **Logic & Utilities**: Convert `$.each`, `$.map`, `$.extend` to native `map`, `filter`, `Object.assign`/spread.
2.  **Async Data**: Replace `$.ajax` with `async/await` and `fetch`.
3.  **DOM Interaction**: Replace selectors and events with `querySelector` and `addEventListener`.
4.  **Modularization**: Convert global scripts to ES Modules (`import`/`export`).

## 2. The Prompt

Use this comprehensive prompt with `orcha-scan` to drive a deep modernization.

```bash
orcha-scan src/client \
  --ext .js \
  --instruction "Refactor this code to remove jQuery and modernize to ES6+.
  
  1. **Async/Await**: Replace '$.ajax', '$.get', '$.post' with 'async/await' and 'fetch'. Handle errors with try/catch.
  2. **Array Methods**: Replace '$.each' with 'forEach' or 'for...of'. Replace '$.map' with '.map()'. Replace '$.grep' with '.filter()'. Use '.some()' and '.every()' where appropriate.
  3. **DOM**: Replace '$()' with 'document.querySelector' or 'document.querySelectorAll'. Replace '.on()' with 'addEventListener'.
  4. **Modern Syntax**: Use 'const' and 'let' instead of 'var'. Use arrow functions '() => {}' to preserve 'this' context where helpful. Use template literals for string concatenation.
  5. **Modules**: If the file looks like a library, export functions using 'export' instead of assigning to 'window' or global objects.
  6. **Safety**: Ensure null checks are added for DOM elements before accessing properties."
```

## 3. Verification

### Automated Testing
Run your test suite. If you are converting to modules, ensure your test runner supports ES modules (e.g., Jest with babel/ts-jest, or native Node test runner).

```bash
orcha-scan src/client --instruction "..." --test-cmd "npm test"
```

### Dry Run
Always inspect the first pass to ensure the AI isn't hallucinating APIs.

```bash
orcha-scan src/client --instruction "..." --dry-run
```

## 4. Modernization Examples

### Async Data Fetching
**Before:**
```javascript
function loadData() {
  $.ajax({
    url: '/api/data',
    method: 'GET',
    success: function(data) {
      process(data);
    },
    error: function(err) {
      console.error(err);
    }
  });
}
```

**After:**
```javascript
async function loadData() {
  try {
    const response = await fetch('/api/data');
    if (!response.ok) throw new Error('Network response was not ok');
    const data = await response.json();
    process(data);
  } catch (err) {
    console.error(err);
  }
}
```

### Array Operations
**Before:**
```javascript
var names = $.map(users, function(user) {
  return user.name;
});
$.each(names, function(i, name) {
  console.log(name);
});
```

**After:**
```javascript
const names = users.map(user => user.name);
names.forEach(name => console.log(name));
```

### DOM & Event Delegation
**Before:**
```javascript
$(document).on('click', '.delete-btn', function() {
  $(this).closest('tr').remove();
});
```

**After:**
```javascript
document.addEventListener('click', (event) => {
  const btn = event.target.closest('.delete-btn');
  if (btn) {
    const row = btn.closest('tr');
    if (row) row.remove();
  }
});
```
