#!/usr/bin/env bash
set -euo pipefail

# prepare.sh for noir-lang/noir
# Docusaurus 3.9.2 in docs/ subdirectory
# Yarn 4.10.3 (Berry), Node >=22
# The docs/ directory is a separate yarn project with its own yarn.lock

REPO_URL="https://github.com/noir-lang/noir"
BRANCH="master"
REPO_DIR="source-repo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[INFO] Node version: $(node --version)"
echo "[INFO] npm version: $(npm --version)"

# Ensure Node 22+ (required by docs/package.json engines and Docusaurus 3.9.2)
NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
if [ "$NODE_MAJOR" -lt 22 ]; then
    echo "[INFO] Node $NODE_MAJOR found, need Node 22. Installing via n..."
    export N_PREFIX="$HOME/.n"
    mkdir -p "$N_PREFIX"
    N_PREFIX="$HOME/.n" n 22
    export PATH="$HOME/.n/bin:$PATH"
    echo "[INFO] Node version after install: $(node --version)"
fi

# Clone repository (skip if already exists)
if [ ! -d "$REPO_DIR" ]; then
    echo "[INFO] Cloning $REPO_URL..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
else
    echo "[INFO] $REPO_DIR already exists, skipping clone."
fi

# Enable corepack for Yarn 4 (docs/.yarnrc.yml has no yarnPath, needs global yarn 4)
echo "[INFO] Enabling corepack for Yarn 4.10.3..."
corepack enable
corepack prepare yarn@4.10.3 --activate
echo "[INFO] Yarn version: $(yarn --version)"

# Install docs dependencies (docs/ is a separate yarn project with its own yarn.lock)
cd "$REPO_DIR/docs"
echo "[INFO] Installing docs dependencies..."
yarn install

# Generate versions.json (required by docusaurus.config.ts)
# The setStable.ts script fetches stable releases from GitHub API
echo "[INFO] Generating versions.json..."
yarn version::stables || {
    echo "[WARN] yarn version::stables failed, creating versions.json from known stable releases"
    # Fall back to known stable versions if GitHub API is unavailable
    curl -s "https://api.github.com/repos/noir-lang/noir/releases?per_page=100" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
stables = [r['tag_name'] for r in data if not r['prerelease'] and 'aztec' not in r['tag_name']][:2]
print(json.dumps(stables))
" > versions.json
}
echo "[INFO] versions.json content: $(cat versions.json)"

# Fix duplicate sidebar translation keys in versioned docs
# versioned_docs/version-v1.0.0-beta.18 has two 'functions' dirs under reference/NoirJS:
#   - reference/NoirJS/noir_js/functions/
#   - reference/NoirJS/noir_wasm/functions/
# Docusaurus uses the directory name as the translation key, causing duplicates.
# Fix: add unique 'key' attributes to _category_.json in any directories that would conflict.
echo "[INFO] Fixing duplicate sidebar translation keys..."
python3 - <<'PYEOF'
import json
import os
import re
from collections import defaultdict

def add_unique_keys_to_version(base_dir):
    """Find all dirs with duplicate basename within a version tree and add unique keys."""
    dir_name_to_paths = defaultdict(list)
    for root, dirs, files in os.walk(base_dir):
        for d in dirs:
            dir_name_to_paths[d].append(os.path.join(root, d))

    fixed = 0
    for dir_name, paths in dir_name_to_paths.items():
        if len(paths) < 2:
            continue
        for dir_path in paths:
            cat_file = os.path.join(dir_path, '_category_.json')
            rel = os.path.relpath(dir_path, base_dir)
            unique_key = re.sub(r'[^a-zA-Z0-9]+', '-', rel).strip('-')

            if os.path.exists(cat_file):
                with open(cat_file) as f:
                    data = json.load(f)
                if 'key' not in data:
                    data['key'] = unique_key
                    with open(cat_file, 'w') as f:
                        json.dump(data, f, indent=2)
                    print(f"  Updated key in {cat_file} -> '{unique_key}'")
                    fixed += 1
            else:
                data = {'label': dir_name, 'key': unique_key}
                with open(cat_file, 'w') as f:
                    json.dump(data, f, indent=2)
                print(f"  Created {cat_file} with key '{unique_key}'")
                fixed += 1
    return fixed

# Process current docs (dev path: docs/)
total = add_unique_keys_to_version('docs')
print(f"Current docs: fixed {total} directories")

# Process versioned docs that are loaded (per versions.json)
if os.path.exists('versions.json'):
    with open('versions.json') as f:
        versions = json.load(f)
    for version in versions:
        ver_dir = f'versioned_docs/version-{version}'
        if os.path.isdir(ver_dir):
            fixed = add_unique_keys_to_version(ver_dir)
            print(f"Version {version}: fixed {fixed} directories")
        else:
            print(f"Version {version}: directory {ver_dir} not found, skipping")

print("Done fixing sidebar translation keys")
PYEOF

echo "[DONE] Repository is ready for docusaurus commands."
