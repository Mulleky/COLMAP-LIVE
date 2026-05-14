#!/usr/bin/env bash

# COLMAP Live / Incremental Image Processor
# Processes images one by one from a folder and incrementally updates a sparse model.
#
# v1.1.0 additions:
#   - Appends JSON stats for every sparse point cloud/model generated or updated.
#   - Tracks point count, registered images, processed images, camera count, and key COLMAP stats.
#
# Requirements:
#   - colmap must be installed and available in PATH, unless --colmap-bin is provided.
#   - python3 must be available for safe JSON logging.

set -uo pipefail

SCRIPT_VERSION="1.1.0"

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

COLMAP_BIN="${COLMAP_BIN:-colmap}"

MATCHER="${MATCHER:-sequential}"             # sequential or exhaustive
CAMERA_MODEL="${CAMERA_MODEL:-PINHOLE}"      # e.g. PINHOLE, SIMPLE_PINHOLE, SIMPLE_RADIAL, OPENCV
SINGLE_CAMERA="${SINGLE_CAMERA:-1}"          # 1 = assume all images share one camera
SEQUENTIAL_OVERLAP="${SEQUENTIAL_OVERLAP:-10}"

WATCH="${WATCH:-0}"
POLL_SECONDS="${POLL_SECONDS:-3}"
RUN_BA="${RUN_BA:-1}"
EXPORT_PLY="${EXPORT_PLY:-1}"
LOG_STATS="${LOG_STATS:-1}"
RESET="${RESET:-0}"
WAIT_FOR_STABLE_FILE="${WAIT_FOR_STABLE_FILE:-1}"
STABLE_FILE_SECONDS="${STABLE_FILE_SECONDS:-1}"

CONFIG_FILE=""

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
  --no-ba                       Skip bundle adjustment after updates.
  --no-ply                      Do not export sparse_live.ply.
  --no-stats                    Do not write JSON point cloud stats.
  --stats-json PATH             Optional JSON stats log path. Default: WORKSPACE/pointcloud_log.json
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
        err "python3 is required for JSON stats logging."
        err "Install python3 or run with --no-stats."
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
    echo "  MATCHER:              $MATCHER"
    echo "  CAMERA_MODEL:         $CAMERA_MODEL"
    echo "  SINGLE_CAMERA:        $SINGLE_CAMERA"
    echo "  SEQUENTIAL_OVERLAP:   $SEQUENTIAL_OVERLAP"
    echo "  RUN_BA:               $RUN_BA"
    echo "  EXPORT_PLY:           $EXPORT_PLY"
    echo "  LOG_STATS:            $LOG_STATS"
    echo "  WATCH:                $WATCH"
    echo "  POLL_SECONDS:         $POLL_SECONDS"
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
            2>&1 | tee "$log_file"
    else
        info "Running exhaustive matcher..."
        "$COLMAP_BIN" exhaustive_matcher \
            --database_path "$DATABASE_PATH" \
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
    model_folder=$(find_first_model_folder "$INIT_OUTPUT_DIR" || true)

    if [ "$mapper_status" -eq 0 ] && [ -n "$model_folder" ]; then
        info "Initial sparse model created: $model_folder"
        rm -rf "$LIVE_MODEL_PATH"
        cp -r "$model_folder" "$LIVE_MODEL_PATH"

        export_ply_if_requested
        append_pointcloud_stats_json "initialized" "$trigger_image"
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
        warn "point_triangulator failed. Keeping previous live model."
        export_ply_if_requested
        return 0
    fi

    local NEW_MODEL_DIR="$TRIANGULATE_DIR"

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

    rm -rf "$WORKSPACE/sparse_live_previous"
    if [ -d "$LIVE_MODEL_PATH" ]; then
        cp -r "$LIVE_MODEL_PATH" "$WORKSPACE/sparse_live_previous"
    fi

    rm -rf "$LIVE_MODEL_PATH"
    cp -r "$NEW_MODEL_DIR" "$LIVE_MODEL_PATH"

    info "Live model updated: $LIVE_MODEL_PATH"
    export_ply_if_requested
    append_pointcloud_stats_json "updated" "$trigger_image"
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
    preparse_config "$@"
    parse_args "$@"
    resolve_defaults

    if [ "$RESET" = "1" ]; then
        reset_project
    fi

    print_config_summary

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
    fi
}

main "$@"
