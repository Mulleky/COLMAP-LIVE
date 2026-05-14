#!/usr/bin/env bash

# Optional convenience launcher for Carlos' current test paths.
# You can edit these two paths and then run:
#   ./run_example_carlos_paths.sh
#
# For live-watch mode:
#   ./run_example_carlos_paths.sh --watch
#
# For reset:
#   ./run_example_carlos_paths.sh --reset

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/colmap_live.sh" \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  "$@"
