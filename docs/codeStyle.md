# codeStyle.md

## Code Style Guidelines

### Shell Scripts
- All shell scripts must be POSIX-compliant (bash/zsh compatible).
- Use `#!/bin/bash` shebang.
- Always call bash scripts with `bash`, not `sh`.
- Use `set -euo pipefail` for safety.
- Quote all variable expansions: `"${var}"`.
- Handle macOS vs Linux differences (e.g., prefer `perl -pi -e` over `sed -i`).
- Avoid bash-specific features unless necessary, and if so, document them clearly.
- Provide clear usage examples and error messages.
- Don't use `read -p "Any prompt: " VAR`, use `echo "Any prompt: "` and `read VAR < /dev/tty`.

## Important Notes

- When this file is updated, warn the user to check and eventually update `codeStyle.md` file in GenericSuite Basecamp project.
