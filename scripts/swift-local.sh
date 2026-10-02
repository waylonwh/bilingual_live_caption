#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"
command_name="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
exec swift "$command_name" --cache-path "$project_dir/.build/cache" \
    --config-path "$project_dir/.build/config" --security-path "$project_dir/.build/security" \
    --build-system native --disable-sandbox "$@"
