---
name: sanity
description: Agent discipline for lean debugging — fetch minimally, replicate before fixing, show patches not prose. Activate when the task involves investigating bugs, reading unfamiliar code, or making changes that require understanding existing behavior.
---

### Fetch Minimally

- only the relevant fields
- top N errors, not all of them
- deduplicate repetitive output
- summarized file trees over full listings
- compact JSON (no pretty-print unless you're reading it)
- filtered logs by timestamp or keyword
- row counts and samples instead of full tables
- extracted function/class names instead of entire source files

Examples: `head -n 100`, `tail -n 100`, `grep -n "pattern" file | head`, `find . -type f | head -n 200`, `python script.py --limit 50`

### Replicate Before Fix

Without reproduction, you cannot ensure the issue is resolved.

- Frontend code → load the page in browser MCP
- Backend code → replicate the issue via a test

### Communicate in Patches

Be concise. No long explanations. Show only the patch and the reason. If `draw` is also loaded, add its diagram too when suited.
