#!/usr/bin/env bash

# COLMAP Live / Incremental Image Processor
# Processes images one by one from a folder and incrementally updates a sparse model.
#
# v1.2.0 additions:
#   - Optionally logs CPU, memory, and NVIDIA GPU usage during each run.
#
# v1.1.0 additions:
#   - Appends JSON stats for every sparse point cloud/model generated or updated.
#   - Tracks point count, registered images, processed images, camera count, and key COLMAP stats.
#
# Requirements:
#   - colmap must be installed and available in PATH, unless --colmap-bin is provided.
#   - python3 must be available for safe JSON logging.

set -uo pipefail

SCRIPT_VERSION="1.2.0"

# ----------------------------
# Defaults. These can be changed by config.env or command-line flags.
# ----------------------------

WORKSPACE="${WORKSPACE:-}"
IMAGE_PATH="${IMAGE_PATH:-}"
DATABASE_PATH="${DATABASE_PATH:-}"
LIVE_MODEL_PATH="${LIVE_MODEL_PATH:-}"
OUTPUT_PLY="${OUTPUT_PLY:-}"
PROCESSED_LIST="${PROCESSED_LIST:-}"
STATS_JSON="${STATS_JSON:-}"
RESOURCE_JSON="${RESOURCE_JSON:-}"

COLMAP_BIN="${COLMAP_BIN:-colmap}"

MATCHER="${MATCHER:-sequential}"             # sequential or exhaustive
CAMERA_MODEL="${CAMERA_MODEL:-PINHOLE}"      # e.g. PINHOLE, SIMPLE_PINHOLE, SIMPLE_RADIAL, OPENCV
SINGLE_CAMERA="${SINGLE_CAMERA:-1}"          # 1 = assume all images share one camera
SEQUENTIAL_OVERLAP="${SEQUENTIAL_OVERLAP:-10}"
USE_GPU="${USE_GPU:-1}"                      # 1 = use GPU for SIFT extraction/matching when available
GPU_INDEX="${GPU_INDEX:--1}"                 # -1 = COLMAP chooses GPU

WATCH="${WATCH:-0}"
POLL_SECONDS="${POLL_SECONDS:-3}"
RUN_BA="${RUN_BA:-1}"
EXPORT_PLY="${EXPORT_PLY:-1}"
LOG_STATS="${LOG_STATS:-1}"
LOG_RESOURCES="${LOG_RESOURCES:-1}"
RESOURCE_SAMPLE_SECONDS="${RESOURCE_SAMPLE_SECONDS:-1}"
REBUILD_ON_TRIANGULATION_FAILURE="${REBUILD_ON_TRIANGULATION_FAILURE:-1}"
RESET="${RESET:-0}"
WAIT_FOR_STABLE_FILE="${WAIT_FOR_STABLE_FILE:-1}"
STABLE_FILE_SECONDS="${STABLE_FILE_SECONDS:-1}"

CONFIG_FILE=""
RESOURCE_MONITOR_PID=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------
# Logging helpers
# ----------------------------

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

err() {
    echo "[ERROR] $*" >&2
}

usage() {
    cat <<EOF
COLMAP Live / Incremental Image Processor v${SCRIPT_VERSION}

Usage:
  ./colmap_live.sh --workspace PATH --image-path PATH [options]
  ./colmap_live.sh --config config.env [options]

Required:
  --workspace PATH              Output/work folder for database, model, logs, temp files.
  --image-path PATH             Folder containing images to process.

Common options:
  --config PATH                 Load variables from a config.env file.
  --watch                       Keep watching for new incoming images.
  --poll-seconds N              Seconds between folder scans in --watch mode. Default: ${POLL_SECONDS}
  --reset                       Delete previous COLMAP database/model/progress/stats files, but keep images.
  --matcher TYPE                sequential or exhaustive. Default: ${MATCHER}
  --camera-model MODEL          COLMAP camera model. Default: ${CAMERA_MODEL}
  --single-camera 0|1           Treat all images as same camera. Default: ${SINGLE_CAMERA}
  --sequential-overlap N        Overlap for sequential matcher. Default: ${SEQUENTIAL_OVERLAP}
  --use-gpu 0|1                 Use GPU for COLMAP SIFT extraction/matching. Default: ${USE_GPU}
  --gpu-index INDEX             GPU index for COLMAP SIFT extraction/matching. Default: ${GPU_INDEX}
  --no-ba                       Skip bundle adjustment after updates.
  --no-ply                      Do not export sparse_live.ply.
  --no-stats                    Do not write JSON point cloud stats.
  --stats-json PATH             Optional JSON stats log path. Default: WORKSPACE/pointcloud_log.json
  --no-resource-monitor         Do not log CPU/GPU resource usage.
  --resource-json PATH          Optional resource usage JSON path. Default: WORKSPACE/resource_usage_log.json
  --resource-sample-seconds N   Seconds between resource samples. Default: ${RESOURCE_SAMPLE_SECONDS}
  --no-rebuild-fallback         Do not run mapper if incremental triangulation fails.
  --database-path PATH          Optional explicit database path. Default: WORKSPACE/database.db
  --live-model-path PATH        Optional explicit live model path. Default: WORKSPACE/sparse_live
  --output-ply PATH             Optional explicit PLY path. Default: WORKSPACE/sparse_live.ply
  --processed-list PATH         Optional processed image list. Default: WORKSPACE/processed_images.txt
  --colmap-bin PATH             Optional path to COLMAP binary. Default: colmap
  --help                        Show this help message.

Examples:
  Process all existing images once:
    ./colmap_live.sh \\
      --workspace /home/carlos/colmap_test/sequential \\
      --image-path /home/carlos/colmap_test/images

  Watch for live incoming images:
    ./colmap_live.sh \\
      --workspace /home/carlos/colmap_test/sequential \\
      --image-path /home/carlos/colmap_test/images \\
      --watch

  Use a config file:
    ./colmap_live.sh --config config.env

Stats JSON:
  The script appends one object per generated/updated sparse point cloud to:
    WORKSPACE/pointcloud_log.json

Resource JSON:
  The script logs CPU, memory, and NVIDIA GPU usage samples to:
    WORKSPACE/resource_usage_log.json

EOF
}

# ----------------------------
# Pre-parse --config so config values can be overridden by later CLI args.
# ----------------------------

preparse_config() {
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        case "${args[$i]}" in
            --config)
                i=$((i + 1))
                if [ $i -ge ${#args[@]} ]; then
                    err "--config requires a path."
                    exit 1
                fi
                CONFIG_FILE="${args[$i]}"
                ;;
        esac
        i=$((i + 1))
    done

    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            err "Config file not found: $CONFIG_FILE"
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --config)
                shift 2
                ;;
            --workspace)
                WORKSPACE="$2"
                shift 2
                ;;
            --image-path)
                IMAGE_PATH="$2"
                shift 2
                ;;
            --database-path)
                DATABASE_PATH="$2"
                shift 2
                ;;
            --live-model-path)
                LIVE_MODEL_PATH="$2"
                shift 2
                ;;
            --output-ply)
                OUTPUT_PLY="$2"
                shift 2
                ;;
            --processed-list)
                PROCESSED_LIST="$2"
                shift 2
                ;;
            --stats-json)
                STATS_JSON="$2"
                shift 2
                ;;
            --resource-json)
                RESOURCE_JSON="$2"
                shift 2
                ;;
            --resource-sample-seconds)
                RESOURCE_SAMPLE_SECONDS="$2"
                shift 2
                ;;
            --colmap-bin)
                COLMAP_BIN="$2"
                shift 2
                ;;
            --watch)
                WATCH="1"
                shift
                ;;
            --poll-seconds)
                POLL_SECONDS="$2"
                shift 2
                ;;
            --reset)
                RESET="1"
                shift
                ;;
            --matcher)
                MATCHER="$2"
                shift 2
                ;;
            --camera-model)
                CAMERA_MODEL="$2"
                shift 2
                ;;
            --single-camera)
                SINGLE_CAMERA="$2"
                shift 2
                ;;
            --sequential-overlap)
                SEQUENTIAL_OVERLAP="$2"
                shift 2
                ;;
            --use-gpu)
                USE_GPU="$2"
                shift 2
                ;;
            --gpu-index)
                GPU_INDEX="$2"
                shift 2
                ;;
            --no-ba)
                RUN_BA="0"
                shift
                ;;
            --no-ply)
                EXPORT_PLY="0"
                shift
                ;;
            --no-stats)
                LOG_STATS="0"
                shift
                ;;
            --no-resource-monitor)
                LOG_RESOURCES="0"
                shift
                ;;
            --no-rebuild-fallback)
                REBUILD_ON_TRIANGULATION_FAILURE="0"
                shift
                ;;
            --no-stable-file-wait)
                WAIT_FOR_STABLE_FILE="0"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                err "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

resolve_defaults() {
    if [ -z "$WORKSPACE" ]; then
        err "Missing required --workspace PATH"
        usage
        exit 1
    fi

    if [ -z "$IMAGE_PATH" ]; then
        err "Missing required --image-path PATH"
        usage
        exit 1
    fi

    DATABASE_PATH="${DATABASE_PATH:-$WORKSPACE/database.db}"
    LIVE_MODEL_PATH="${LIVE_MODEL_PATH:-$WORKSPACE/sparse_live}"
    OUTPUT_PLY="${OUTPUT_PLY:-$WORKSPACE/sparse_live.ply}"
    PROCESSED_LIST="${PROCESSED_LIST:-$WORKSPACE/processed_images.txt}"
    STATS_JSON="${STATS_JSON:-$WORKSPACE/pointcloud_log.json}"
    RESOURCE_JSON="${RESOURCE_JSON:-$WORKSPACE/resource_usage_log.json}"

    LIST_DIR="$WORKSPACE/lists"
    TMP_DIR="$WORKSPACE/tmp"
    LOG_DIR="$WORKSPACE/logs"
    INIT_OUTPUT_DIR="$WORKSPACE/sparse_init_attempt"

    mkdir -p "$WORKSPACE" "$LIST_DIR" "$TMP_DIR" "$LOG_DIR"

    if [ ! -d "$IMAGE_PATH" ]; then
        err "Image folder does not exist: $IMAGE_PATH"
        exit 1
    fi

    if ! command -v "$COLMAP_BIN" >/dev/null 2>&1 && [ ! -x "$COLMAP_BIN" ]; then
        err "COLMAP binary not found: $COLMAP_BIN"
        err "Install COLMAP or pass --colmap-bin /path/to/colmap"
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        err "python3 is required for JSON stats/resource logging."
        err "Install python3 or run with --no-stats --no-resource-monitor."
        exit 1
    fi

    if [ "$LOG_RESOURCES" = "1" ] && [ ! -f "$SCRIPT_DIR/monitor_system_usage.py" ]; then
        err "Resource monitor script not found: $SCRIPT_DIR/monitor_system_usage.py"
        err "Restore it or run with --no-resource-monitor."
        exit 1
    fi

    case "$MATCHER" in
        sequential|exhaustive)
            ;;
        *)
            err "--matcher must be either sequential or exhaustive."
            exit 1
            ;;
    esac

    touch "$PROCESSED_LIST"
}

reset_project() {
    warn "Reset requested. This deletes COLMAP database/model/progress/stats files but keeps images."
    rm -f "$DATABASE_PATH"
    rm -f "$OUTPUT_PLY"
    rm -f "$PROCESSED_LIST"
    rm -f "$STATS_JSON"
    rm -f "$RESOURCE_JSON"
    rm -rf "$LIVE_MODEL_PATH"
    rm -rf "$WORKSPACE/sparse_live_previous"
    rm -rf "$TMP_DIR"
    rm -rf "$INIT_OUTPUT_DIR"
    mkdir -p "$TMP_DIR"
    touch "$PROCESSED_LIST"
}

print_config_summary() {
    info "Configuration:"
    echo "  WORKSPACE:            $WORKSPACE"
    echo "  IMAGE_PATH:           $IMAGE_PATH"
    echo "  DATABASE_PATH:        $DATABASE_PATH"
    echo "  LIVE_MODEL_PATH:      $LIVE_MODEL_PATH"
    echo "  OUTPUT_PLY:           $OUTPUT_PLY"
    echo "  PROCESSED_LIST:       $PROCESSED_LIST"
    echo "  STATS_JSON:           $STATS_JSON"
    echo "  RESOURCE_JSON:        $RESOURCE_JSON"
    echo "  MATCHER:              $MATCHER"
    echo "  CAMERA_MODEL:         $CAMERA_MODEL"
    echo "  SINGLE_CAMERA:        $SINGLE_CAMERA"
    echo "  SEQUENTIAL_OVERLAP:   $SEQUENTIAL_OVERLAP"
    echo "  USE_GPU:              $USE_GPU"
    echo "  GPU_INDEX:            $GPU_INDEX"
    echo "  RUN_BA:               $RUN_BA"
    echo "  EXPORT_PLY:           $EXPORT_PLY"
    echo "  LOG_STATS:            $LOG_STATS"
    echo "  LOG_RESOURCES:        $LOG_RESOURCES"
    echo "  RESOURCE_SAMPLE_SEC:  $RESOURCE_SAMPLE_SECONDS"
    echo "  REBUILD_ON_TRI_FAIL:  $REBUILD_ON_TRIANGULATION_FAILURE"
    echo "  WATCH:                $WATCH"
    echo "  POLL_SECONDS:         $POLL_SECONDS"
}

start_resource_monitor() {
    if [ "$LOG_RESOURCES" != "1" ]; then
        return 0
    fi

    info "Starting resource monitor: $RESOURCE_JSON"
    python3 "$SCRIPT_DIR/monitor_system_usage.py" \
        --output-json "$RESOURCE_JSON" \
        --sample-seconds "$RESOURCE_SAMPLE_SECONDS" \
        --run-label "colmap_live" &
    RESOURCE_MONITOR_PID=$!
}

stop_resource_monitor() {
    if [ -z "$RESOURCE_MONITOR_PID" ]; then
        return 0
    fi

    if kill -0 "$RESOURCE_MONITOR_PID" 2>/dev/null; then
        info "Stopping resource monitor..."
        kill "$RESOURCE_MONITOR_PID" 2>/dev/null
        wait "$RESOURCE_MONITOR_PID" 2>/dev/null
    fi

    RESOURCE_MONITOR_PID=""
}

cleanup_and_exit() {
    local exit_code=$?
    stop_resource_monitor
    exit "$exit_code"
}

is_image_file() {
    local f="$1"
    case "${f,,}" in
        *.jpg|*.jpeg|*.png|*.tif|*.tiff)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wait_until_file_is_stable() {
    local file="$1"

    if [ "$WAIT_FOR_STABLE_FILE" != "1" ]; then
        return 0
    fi

    if [ ! -f "$file" ]; then
        return 1
    fi

    local size1
    local size2

    size1=$(stat -c%s "$file" 2>/dev/null || echo 0)
    sleep "$STABLE_FILE_SECONDS"
    size2=$(stat -c%s "$file" 2>/dev/null || echo 0)

    if [ "$size1" = "$size2" ] && [ "$size1" -gt 0 ]; then
        return 0
    fi

    warn "File is still changing or empty, skipping for now: $file"
    return 1
}

count_processed_images_including_trigger() {
    local trigger_image="$1"
    local count

    count=$(awk 'NF' "$PROCESSED_LIST" 2>/dev/null | sort -u | wc -l | tr -d ' ')

    if [ -n "$trigger_image" ] && ! grep -Fxq "$trigger_image" "$PROCESSED_LIST" 2>/dev/null; then
        count=$((count + 1))
    fi

    echo "$count"
}

append_pointcloud_stats_json() {
    local event_name="$1"
    local trigger_image="$2"

    if [ "$LOG_STATS" != "1" ]; then
        return 0
    fi

    if [ ! -f "$LIVE_MODEL_PATH/images.bin" ]; then
        warn "Stats not written because live model does not exist yet."
        return 0
    fi

    local stats_txt_dir="$TMP_DIR/stats_txt"
    rm -rf "$stats_txt_dir"
    mkdir -p "$stats_txt_dir"

    info "Converting sparse model to TXT for stats extraction..."

    "$COLMAP_BIN" model_converter \
        --input_path "$LIVE_MODEL_PATH" \
        --output_path "$stats_txt_dir" \
        --output_type TXT \
        >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        warn "Could not convert model to TXT; JSON stats were not updated."
        return 0
    fi

    local processed_count
    processed_count=$(count_processed_images_including_trigger "$trigger_image")

    python3 - "$STATS_JSON" "$stats_txt_dir" "$event_name" "$trigger_image" \
        "$WORKSPACE" "$IMAGE_PATH" "$DATABASE_PATH" "$LIVE_MODEL_PATH" "$OUTPUT_PLY" \
        "$processed_count" "$MATCHER" "$CAMERA_MODEL" "$SINGLE_CAMERA" "$SEQUENTIAL_OVERLAP" "$RUN_BA" "$EXPORT_PLY" <<'PY'
import json
import math
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    stats_json_path,
    stats_txt_dir,
    event_name,
    trigger_image,
    workspace,
    image_path,
    database_path,
    live_model_path,
    output_ply,
    processed_count,
    matcher,
    camera_model,
    single_camera,
    sequential_overlap,
    run_ba,
    export_ply,
) = sys.argv[1:]

stats_json_path = Path(stats_json_path)
stats_txt_dir = Path(stats_txt_dir)

def read_text(path):
    try:
        return Path(path).read_text(errors="replace")
    except FileNotFoundError:
        return ""

def parse_int_from_comment(text, pattern):
    match = re.search(pattern, text)
    if match:
        try:
            return int(match.group(1))
        except ValueError:
            return None
    return None

def parse_float_from_comment(text, pattern):
    match = re.search(pattern, text)
    if match:
        try:
            return float(match.group(1))
        except ValueError:
            return None
    return None

cameras_txt = read_text(stats_txt_dir / "cameras.txt")
images_txt = read_text(stats_txt_dir / "images.txt")
points_txt = read_text(stats_txt_dir / "points3D.txt")

camera_count = parse_int_from_comment(cameras_txt, r"#\s*Number of cameras:\s*(\d+)")
registered_image_count = parse_int_from_comment(images_txt, r"#\s*Number of images:\s*(\d+)")
point_count = parse_int_from_comment(points_txt, r"#\s*Number of points:\s*(\d+)")

mean_observations_per_image = parse_float_from_comment(
    images_txt,
    r"mean observations per image:\s*([0-9.+\-eE]+)"
)

mean_track_length = parse_float_from_comment(
    points_txt,
    r"mean track length:\s*([0-9.+\-eE]+)"
)

# Fallbacks if COLMAP comment headers are absent.
if camera_count is None:
    camera_count = sum(
        1 for line in cameras_txt.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )

if point_count is None:
    point_count = sum(
        1 for line in points_txt.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    )

if registered_image_count is None:
    # COLMAP images.txt stores two logical lines per image after comments:
    # image metadata line, then points2D line.
    non_comment_lines = [
        line for line in images_txt.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    registered_image_count = len(non_comment_lines) // 2

try:
    processed_count = int(processed_count)
except ValueError:
    processed_count = None

def file_exists(path):
    return Path(path).exists()

def file_size(path):
    p = Path(path)
    return p.stat().st_size if p.exists() else None

# The JSON file is maintained as a list of snapshots.
if stats_json_path.exists():
    try:
        data = json.loads(stats_json_path.read_text())
        if not isinstance(data, list):
            data = []
    except Exception:
        data = []
else:
    data = []

record = {
    "point_cloud_id": len(data) + 1,
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "event": event_name,
    "trigger_image": trigger_image or None,

    "counts": {
        "processed_images_including_trigger": processed_count,
        "registered_images_in_sparse_model": registered_image_count,
        "cameras_in_sparse_model": camera_count,
        "sparse_3d_points": point_count,
    },

    "quality_summary": {
        "mean_observations_per_registered_image": mean_observations_per_image,
        "mean_track_length": mean_track_length,
    },

    "paths": {
        "workspace": workspace,
        "image_path": image_path,
        "database_path": database_path,
        "live_model_path": live_model_path,
        "output_ply": output_ply,
        "output_ply_exists": file_exists(output_ply),
        "output_ply_size_bytes": file_size(output_ply),
    },

    "settings": {
        "matcher": matcher,
        "camera_model": camera_model,
        "single_camera": single_camera == "1",
        "sequential_overlap": int(sequential_overlap) if str(sequential_overlap).isdigit() else sequential_overlap,
        "bundle_adjustment_enabled": run_ba == "1",
        "ply_export_enabled": export_ply == "1",
    },
}

data.append(record)

stats_json_path.parent.mkdir(parents=True, exist_ok=True)
stats_json_path.write_text(json.dumps(data, indent=2) + "\n")

print(f"[INFO] JSON point cloud stats appended: {stats_json_path}")
print(f"[INFO] Latest point cloud stats: registered_images={registered_image_count}, sparse_3d_points={point_count}, processed_images={processed_count}")
PY
}

run_matcher() {
    local log_file="$LOG_DIR/matcher_$(date +%Y%m%d_%H%M%S).log"

    if [ "$MATCHER" = "sequential" ]; then
        info "Running sequential matcher..."
        "$COLMAP_BIN" sequential_matcher \
            --database_path "$DATABASE_PATH" \
            --SequentialMatching.overlap "$SEQUENTIAL_OVERLAP" \
            --SiftMatching.use_gpu "$USE_GPU" \
            --SiftMatching.gpu_index "$GPU_INDEX" \
            2>&1 | tee "$log_file"
    else
        info "Running exhaustive matcher..."
        "$COLMAP_BIN" exhaustive_matcher \
            --database_path "$DATABASE_PATH" \
            --SiftMatching.use_gpu "$USE_GPU" \
            --SiftMatching.gpu_index "$GPU_INDEX" \
            2>&1 | tee "$log_file"
    fi

    return ${PIPESTATUS[0]}
}

export_ply_if_requested() {
    if [ "$EXPORT_PLY" != "1" ]; then
        return 0
    fi

    if [ ! -f "$LIVE_MODEL_PATH/images.bin" ]; then
        warn "No live model exists yet, so no PLY was exported."
        return 0
    fi

    info "Exporting current sparse model to PLY..."
    "$COLMAP_BIN" model_converter \
        --input_path "$LIVE_MODEL_PATH" \
        --output_path "$OUTPUT_PLY" \
        --output_type PLY

    if [ $? -eq 0 ]; then
        info "PLY updated: $OUTPUT_PLY"
    else
        warn "PLY export failed. Keeping current model."
    fi
}

find_first_model_folder() {
    local parent="$1"
    find "$parent" -mindepth 1 -maxdepth 1 -type d | sort | while read -r d; do
        if [ -f "$d/images.bin" ] && [ -f "$d/cameras.bin" ] && [ -f "$d/points3D.bin" ]; then
            echo "$d"
            return 0
        fi
    done
}

count_sparse_points_in_model() {
    local model_path="$1"

    if [ ! -f "$model_path/points3D.bin" ]; then
        echo 0
        return 0
    fi

    local count_txt_dir
    count_txt_dir=$(mktemp -d "$TMP_DIR/model_count_XXXXXX")

    "$COLMAP_BIN" model_converter \
        --input_path "$model_path" \
        --output_path "$count_txt_dir" \
        --output_type TXT \
        >/dev/null 2>&1

    if [ $? -ne 0 ] || [ ! -f "$count_txt_dir/points3D.txt" ]; then
        rm -rf "$count_txt_dir"
        echo 0
        return 0
    fi

    awk '
        /^# Number of points:/ {
            gsub(",", "", $5)
            print $5
            found=1
            exit
        }
        END {
            if (!found) {
                count=0
                while ((getline line < ARGV[1]) > 0) {
                    if (line !~ /^#/ && line !~ /^[[:space:]]*$/) {
                        count++
                    }
                }
                print count
            }
        }
    ' "$count_txt_dir/points3D.txt"

    rm -rf "$count_txt_dir"
}

find_best_model_folder() {
    local parent="$1"
    local best_model=""
    local best_points=-1

    while IFS= read -r d; do
        if [ -f "$d/images.bin" ] && [ -f "$d/cameras.bin" ] && [ -f "$d/points3D.bin" ]; then
            local point_count
            point_count=$(count_sparse_points_in_model "$d")

            if [ "$point_count" -gt "$best_points" ]; then
                best_points="$point_count"
                best_model="$d"
            fi
        fi
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ -n "$best_model" ]; then
        echo "$best_model"
    fi
}

replace_live_model_from() {
    local new_model_dir="$1"
    local event_name="$2"
    local trigger_image="$3"

    rm -rf "$WORKSPACE/sparse_live_previous"
    if [ -d "$LIVE_MODEL_PATH" ]; then
        cp -r "$LIVE_MODEL_PATH" "$WORKSPACE/sparse_live_previous"
    fi

    rm -rf "$LIVE_MODEL_PATH"
    cp -r "$new_model_dir" "$LIVE_MODEL_PATH"

    info "Live model updated: $LIVE_MODEL_PATH"
    export_ply_if_requested
    append_pointcloud_stats_json "$event_name" "$trigger_image"
}

rebuild_model_from_database() {
    local trigger_image="$1"
    local reason="$2"

    if [ "$REBUILD_ON_TRIANGULATION_FAILURE" != "1" ]; then
        warn "Rebuild fallback disabled. Keeping previous live model."
        export_ply_if_requested
        return 0
    fi

    local rebuild_dir="$TMP_DIR/rebuild_mapper"
    rm -rf "$rebuild_dir"
    mkdir -p "$rebuild_dir"

    info "Running full mapper rebuild from accumulated database because: $reason"

    local rebuild_log="$LOG_DIR/mapper_rebuild_$(date +%Y%m%d_%H%M%S).log"

    "$COLMAP_BIN" mapper \
        --database_path "$DATABASE_PATH" \
        --image_path "$IMAGE_PATH" \
        --output_path "$rebuild_dir" \
        2>&1 | tee "$rebuild_log"

    local mapper_status=${PIPESTATUS[0]}
    local best_model
    best_model=$(find_best_model_folder "$rebuild_dir" || true)

    if [ "$mapper_status" -ne 0 ] || [ -z "$best_model" ]; then
        warn "Mapper rebuild did not produce a usable model. Keeping previous live model."
        export_ply_if_requested
        return 0
    fi

    local current_points
    local rebuilt_points
    current_points=$(count_sparse_points_in_model "$LIVE_MODEL_PATH")
    rebuilt_points=$(count_sparse_points_in_model "$best_model")

    if [ "$rebuilt_points" -lt "$current_points" ]; then
        warn "Mapper rebuild produced fewer points ($rebuilt_points) than current model ($current_points). Keeping previous live model."
        export_ply_if_requested
        return 0
    fi

    info "Mapper rebuild selected model: $best_model ($rebuilt_points sparse points)."
    replace_live_model_from "$best_model" "rebuilt" "$trigger_image"
    return 0
}

try_initialize_model() {
    local trigger_image="$1"

    info "No live model exists yet. Trying to initialize sparse model..."

    rm -rf "$INIT_OUTPUT_DIR"
    mkdir -p "$INIT_OUTPUT_DIR"

    local log_file="$LOG_DIR/mapper_$(date +%Y%m%d_%H%M%S).log"

    "$COLMAP_BIN" mapper \
        --database_path "$DATABASE_PATH" \
        --image_path "$IMAGE_PATH" \
        --output_path "$INIT_OUTPUT_DIR" \
        2>&1 | tee "$log_file"

    local mapper_status=${PIPESTATUS[0]}

    local model_folder
    model_folder=$(find_best_model_folder "$INIT_OUTPUT_DIR" || true)

    if [ "$mapper_status" -eq 0 ] && [ -n "$model_folder" ]; then
        info "Initial sparse model created: $model_folder"
        replace_live_model_from "$model_folder" "initialized" "$trigger_image"
        return 0
    fi

    warn "Sparse model could not initialize yet. This is normal for the first few images."
    warn "Need enough overlap, baseline, and matches before COLMAP can make a 3D model."
    return 0
}

update_existing_model() {
    local trigger_image="$1"

    info "Live model exists. Registering/triangulating new information..."

    local REGISTER_DIR="$TMP_DIR/register"
    local TRIANGULATE_DIR="$TMP_DIR/triangulate"
    local BA_DIR="$TMP_DIR/ba"

    rm -rf "$REGISTER_DIR" "$TRIANGULATE_DIR" "$BA_DIR"
    mkdir -p "$REGISTER_DIR" "$TRIANGULATE_DIR" "$BA_DIR"

    local reg_log="$LOG_DIR/image_registrator_$(date +%Y%m%d_%H%M%S).log"

    "$COLMAP_BIN" image_registrator \
        --database_path "$DATABASE_PATH" \
        --input_path "$LIVE_MODEL_PATH" \
        --output_path "$REGISTER_DIR" \
        2>&1 | tee "$reg_log"

    local reg_status=${PIPESTATUS[0]}

    if [ "$reg_status" -ne 0 ] || [ ! -f "$REGISTER_DIR/images.bin" ]; then
        warn "image_registrator did not produce an updated model. Keeping previous live model."
        export_ply_if_requested
        return 0
    fi

    local tri_log="$LOG_DIR/point_triangulator_$(date +%Y%m%d_%H%M%S).log"

    "$COLMAP_BIN" point_triangulator \
        --database_path "$DATABASE_PATH" \
        --image_path "$IMAGE_PATH" \
        --input_path "$REGISTER_DIR" \
        --output_path "$TRIANGULATE_DIR" \
        2>&1 | tee "$tri_log"

    local tri_status=${PIPESTATUS[0]}

    if [ "$tri_status" -ne 0 ] || [ ! -f "$TRIANGULATE_DIR/images.bin" ]; then
        warn "point_triangulator failed."
        rebuild_model_from_database "$trigger_image" "point_triangulator failed"
        return 0
    fi

    local NEW_MODEL_DIR="$TRIANGULATE_DIR"
    local live_points_before
    local tri_points
    live_points_before=$(count_sparse_points_in_model "$LIVE_MODEL_PATH")
    tri_points=$(count_sparse_points_in_model "$TRIANGULATE_DIR")

    if [ "$tri_points" -lt "$live_points_before" ]; then
        warn "point_triangulator produced fewer points ($tri_points) than the current live model ($live_points_before)."
        rebuild_model_from_database "$trigger_image" "incremental triangulation degraded the model"
        return 0
    fi

    if [ "$RUN_BA" = "1" ]; then
        local ba_log="$LOG_DIR/bundle_adjuster_$(date +%Y%m%d_%H%M%S).log"

        "$COLMAP_BIN" bundle_adjuster \
            --input_path "$TRIANGULATE_DIR" \
            --output_path "$BA_DIR" \
            2>&1 | tee "$ba_log"

        local ba_status=${PIPESTATUS[0]}

        if [ "$ba_status" -eq 0 ] && [ -f "$BA_DIR/images.bin" ]; then
            NEW_MODEL_DIR="$BA_DIR"
        else
            warn "bundle_adjuster failed. Using triangulated model instead."
            NEW_MODEL_DIR="$TRIANGULATE_DIR"
        fi
    fi

    replace_live_model_from "$NEW_MODEL_DIR" "updated" "$trigger_image"
    return 0
}

try_update_model() {
    local trigger_image="$1"

    if [ ! -f "$LIVE_MODEL_PATH/images.bin" ]; then
        try_initialize_model "$trigger_image"
    else
        update_existing_model "$trigger_image"
    fi
}

process_one_image() {
    local img_path="$1"
    local img_name
    img_name=$(basename "$img_path")

    if ! is_image_file "$img_path"; then
        return 0
    fi

    if grep -Fxq "$img_name" "$PROCESSED_LIST"; then
        info "Skipping already processed image: $img_name"
        return 0
    fi

    if ! wait_until_file_is_stable "$img_path"; then
        return 0
    fi

    info "============================================================"
    info "Processing image: $img_name"
    info "============================================================"

    local list_file="$LIST_DIR/new_image.txt"
    echo "$img_name" > "$list_file"

    info "Extracting features for: $img_name"

    "$COLMAP_BIN" feature_extractor \
        --database_path "$DATABASE_PATH" \
        --image_path "$IMAGE_PATH" \
        --image_list_path "$list_file" \
        --ImageReader.single_camera "$SINGLE_CAMERA" \
        --ImageReader.camera_model "$CAMERA_MODEL" \
        --SiftExtraction.use_gpu "$USE_GPU" \
        --SiftExtraction.gpu_index "$GPU_INDEX" \
        2>&1 | tee "$LOG_DIR/feature_extractor_$(date +%Y%m%d_%H%M%S).log"

    local feature_status=${PIPESTATUS[0]}

    if [ "$feature_status" -ne 0 ]; then
        warn "Feature extraction failed for: $img_name"
        warn "Image will NOT be marked as processed."
        return 0
    fi

    run_matcher
    local matcher_status=$?

    if [ "$matcher_status" -ne 0 ]; then
        warn "Matcher failed after image: $img_name"
        warn "Image will NOT be marked as processed."
        return 0
    fi

    try_update_model "$img_name"

    echo "$img_name" >> "$PROCESSED_LIST"
    info "Marked as processed: $img_name"
}

process_all_available_images() {
    local found_any=0

    while IFS= read -r -d '' img_path; do
        found_any=1
        process_one_image "$img_path"
    done < <(find "$IMAGE_PATH" -maxdepth 1 -type f \
        \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.tif" -o -iname "*.tiff" \) \
        -print0 | sort -z)

    if [ "$found_any" -eq 0 ]; then
        warn "No supported images found in: $IMAGE_PATH"
    fi
}

main() {
    trap cleanup_and_exit EXIT INT TERM

    preparse_config "$@"
    parse_args "$@"
    resolve_defaults

    if [ "$RESET" = "1" ]; then
        reset_project
    fi

    print_config_summary
    start_resource_monitor

    if [ "$WATCH" = "1" ]; then
        info "Watch mode enabled. Press Ctrl+C to stop."
        while true; do
            process_all_available_images
            sleep "$POLL_SECONDS"
        done
    else
        process_all_available_images
        info "Finished processing currently available images."
        info "Current live model path: $LIVE_MODEL_PATH"
        info "Current PLY path:        $OUTPUT_PLY"
        info "JSON stats log path:     $STATS_JSON"
        info "Resource JSON log path:  $RESOURCE_JSON"
    fi
}

main "$@"
