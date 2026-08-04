#!/usr/bin/env bash
# Generate the standalone slashwork-sh/hermes-plugin repo tree from this
# directory.
#
# `hermes plugins install owner/repo` shallow-clones a whole repo into
# ~/.hermes/plugins/<name>/ and expects plugin.yaml and __init__.py at the root,
# so the Hermes adapter cannot be installed from a subdirectory of this repo.
# This directory stays the source of truth; the standalone repo is generated.
#
#   bash adapters/hermes/sync-plugin-repo.sh [target-dir]
#
# Default target: ../hermes-plugin (a sibling checkout of the plugin repo).
# The script only writes files; committing and pushing is left to the operator.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SRC/../.." && pwd)"
TARGET="${1:-$(cd "$REPO_ROOT/.." && pwd)/hermes-plugin}"

mkdir -p "$TARGET"

# The plugin itself, at the repo root where the Hermes installer expects it.
cp "$SRC/__init__.py" "$TARGET/__init__.py"
cp "$SRC/plugin.yaml" "$TARGET/plugin.yaml"
cp "$SRC/README.md" "$TARGET/README.md"
cp "$SRC/test_hermes.py" "$TARGET/test_hermes.py"
cp "$REPO_ROOT/LICENSE" "$TARGET/LICENSE"

cat > "$TARGET/.gitignore" <<'EOF'
__pycache__/
*.pyc
EOF

# A generated repo needs to say so, or someone will edit it there and lose the
# change on the next sync.
cat > "$TARGET/GENERATED.md" <<'EOF'
# This repo is generated

The source of truth is `adapters/hermes/` in
[slashwork-sh/plugin](https://github.com/slashwork-sh/plugin). This repo exists
because `hermes plugins install owner/repo` clones a whole repo and expects
`plugin.yaml` and `__init__.py` at the root.

Edit the adapter there, then run:

```
bash adapters/hermes/sync-plugin-repo.sh
```

and commit the result here. Changes made directly in this repo are lost on the
next sync.
EOF

printf 'synced to %s\n' "$TARGET"
printf '\nnext:\n'
printf '  cd %s\n' "$TARGET"
printf '  python3 -m unittest test_hermes.py\n'
printf '  git init -b main && git add -A && git commit -m "sync from slashwork-sh/plugin"\n'
printf '  gh repo create slashwork-sh/hermes-plugin --public --source=. --push\n'
