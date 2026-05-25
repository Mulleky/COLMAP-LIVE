#!/usr/bin/env bash

IMG_DIR="/home/carlos/colmap_live_pipeline/images"
VIDEO_DEV="/dev/video0"
HZ=1.0
SHOW_RAW=0
SHOW_SLOW=0

ROS_DISTRO=$(ls /opt/ros | head -n 1)

while getopts "i:v:h:-:" opt; do
  case $opt in
    i) IMG_DIR="$OPTARG" ;;
    v) VIDEO_DEV="$OPTARG" ;;
    h) HZ="$OPTARG" ;;
    -)
      case "${OPTARG}" in
        r1) SHOW_RAW=1 ;;
        r2) SHOW_SLOW=1 ;;
      esac
      ;;
  esac
done

if [ -z "$IMG_DIR" ]; then
  echo "Usage: -i <img_dir> -v <video_dev> -h <hz> [--r1] [--r2]"
  exit 1
fi

mkdir -p "$IMG_DIR"
source /opt/ros/$ROS_DISTRO/setup.bash

echo "Starting ROS2 COLMAP pipeline..."

# =========================
# Store PIDs
# =========================
PIDS=()

# =========================
# Ctrl+C handler
# =========================
cleanup() {
  echo ""
  echo "Stopping all processes..."

  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done

  # extra safety: kill any leftover ROS nodes
  pkill -f usb_cam 2>/dev/null
  pkill -f topic_tools 2>/dev/null
  pkill -f image_saver 2>/dev/null
  pkill -f rqt_image_view 2>/dev/null

  echo "All processes stopped."
  exit 0
}

trap cleanup SIGINT SIGTERM

# =========================
# Start nodes
# =========================

ros2 run usb_cam usb_cam_node_exe \
  --ros-args -p video_device:=$VIDEO_DEV -p pixel_format:=yuyv -p image_width:=640   -p image_height:=360 &
PIDS+=($!)

ros2 run topic_tools throttle messages /image_raw $HZ /image_slow &
PIDS+=($!)

(
  cd "$IMG_DIR"
  ros2 run image_view image_saver --ros-args -r image:=/image_slow
) &
PIDS+=($!)

if [ "$SHOW_RAW" -eq 1 ]; then
  ros2 run rqt_image_view rqt_image_view /image_raw &
  PIDS+=($!)
fi

if [ "$SHOW_SLOW" -eq 1 ]; then
  ros2 run rqt_image_view rqt_image_view /image_slow &
  PIDS+=($!)
fi

# =========================
# Keep alive
# =========================
wait
