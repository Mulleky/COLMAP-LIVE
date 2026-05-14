# COLMAP Live / Incremental Image Processor

This folder contains scripts to process images one by one with COLMAP and keep updating a sparse model as new images become available.

It supports two modes:

1. **Batch mode**: all images are already in the folder, and the script processes them one by one.
2. **Watch mode**: the script keeps watching the image folder and processes new incoming images as they appear.

This is a practical COLMAP-based approximation of online/incremental SfM. It is not true real-time SLAM, but it is useful for testing a workflow where images arrive sequentially and the sparse model is updated repeatedly.

---

## Folder structure

```text
colmap_live_pipeline/
├── colmap_live.sh
├── config.env
├── run_example_carlos_paths.sh
└── README.md
```

Your COLMAP working folder will look like this after running:

```text
/home/carlos/colmap_test/
├── images/
│   ├── frame_0001.jpg
│   ├── frame_0002.jpg
│   └── ...
└── sequential/
    ├── database.db
    ├── processed_images.txt
    ├── pointcloud_log.json
    ├── sparse_live/
    │   ├── cameras.bin
    │   ├── images.bin
    │   └── points3D.bin
    ├── sparse_live.ply
    ├── sparse_live_previous/
    ├── sparse_init_attempt/
    ├── lists/
    ├── logs/
    └── tmp/
```

---

## What the script does

For each image in the image folder:

```text
new image
  ↓
extract COLMAP features only for that image
  ↓
match it against the database
  ↓
if no sparse model exists:
    try to initialize a sparse model
else:
    register new image into current model
    triangulate new points
    optionally run bundle adjustment
  ↓
export/update sparse_live.ply
  ↓
append stats to pointcloud_log.json
```

Important: the first image usually cannot produce a 3D sparse cloud. You normally need multiple images with enough overlap and baseline before COLMAP can initialize a model.

---

## JSON stats log

Every time a sparse point cloud/model is successfully initialized or updated, the script appends one JSON object to:

```text
/home/carlos/colmap_test/sequential/pointcloud_log.json
```

The file is a JSON array, not JSONL.

Example:

```json
[
  {
    "point_cloud_id": 1,
    "timestamp_utc": "2026-05-13T19:45:00.000000+00:00",
    "event": "initialized",
    "trigger_image": "frame_0004.jpg",
    "counts": {
      "processed_images_including_trigger": 4,
      "registered_images_in_sparse_model": 4,
      "cameras_in_sparse_model": 1,
      "sparse_3d_points": 1532
    },
    "quality_summary": {
      "mean_observations_per_registered_image": 920.5,
      "mean_track_length": 3.2
    },
    "paths": {
      "workspace": "/home/carlos/colmap_test/sequential",
      "image_path": "/home/carlos/colmap_test/images",
      "database_path": "/home/carlos/colmap_test/sequential/database.db",
      "live_model_path": "/home/carlos/colmap_test/sequential/sparse_live",
      "output_ply": "/home/carlos/colmap_test/sequential/sparse_live.ply",
      "output_ply_exists": true,
      "output_ply_size_bytes": 123456
    },
    "settings": {
      "matcher": "sequential",
      "camera_model": "PINHOLE",
      "single_camera": true,
      "sequential_overlap": 10,
      "bundle_adjustment_enabled": true,
      "ply_export_enabled": true
    }
  }
]
```

The most important fields are:

```text
counts.sparse_3d_points
counts.registered_images_in_sparse_model
counts.processed_images_including_trigger
quality_summary.mean_track_length
```

---

## Setup

Unzip the downloaded folder, then go into it:

```bash
cd /path/to/colmap_live_pipeline
```

Make the scripts executable:

```bash
chmod +x colmap_live.sh
chmod +x run_example_carlos_paths.sh
```

You only need to do that once.

---

## Option A: Run with Carlos' current paths

Process all existing images once:

```bash
./run_example_carlos_paths.sh
```

Start fresh and process all existing images:

```bash
./run_example_carlos_paths.sh --reset
```

Watch for new incoming images:

```bash
./run_example_carlos_paths.sh --watch
```

Stop watch mode with:

```text
Ctrl+C
```

---

## Option B: Run with command-line paths

Process all existing images once:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images
```

Start fresh and process all existing images:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --reset
```

Watch for new incoming images:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --watch
```

---

## Option C: Run with `config.env`

Edit `config.env`:

```bash
nano config.env
```

Set:

```bash
WORKSPACE="/home/carlos/colmap_test/sequential"
IMAGE_PATH="/home/carlos/colmap_test/images"
```

Then run:

```bash
./colmap_live.sh --config config.env
```

Watch mode:

```bash
./colmap_live.sh --config config.env --watch
```

Reset and rerun:

```bash
./colmap_live.sh --config config.env --reset
```

---

## Useful flags

### Change JSON log path

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --stats-json /home/carlos/colmap_test/sequential/my_stats.json
```

### Disable JSON stats logging

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --no-stats
```

### Change matcher

For video/drone-like image sequences:

```bash
--matcher sequential
```

For small unordered image sets:

```bash
--matcher exhaustive
```

Example:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --matcher exhaustive
```

### Change camera model

Examples:

```bash
--camera-model PINHOLE
--camera-model SIMPLE_PINHOLE
--camera-model SIMPLE_RADIAL
--camera-model OPENCV
```

Example:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --camera-model SIMPLE_RADIAL
```

### Skip bundle adjustment for speed

```bash
--no-ba
```

This makes updates faster but less refined.

### Disable PLY export

```bash
--no-ply
```

Useful if you only care about COLMAP `.bin` sparse model files.

---

## Output files

Current sparse model:

```text
/home/carlos/colmap_test/sequential/sparse_live/
```

Expected files after a model exists:

```text
cameras.bin
images.bin
points3D.bin
```

Current PLY export:

```text
/home/carlos/colmap_test/sequential/sparse_live.ply
```

JSON stats log:

```text
/home/carlos/colmap_test/sequential/pointcloud_log.json
```

Logs:

```text
/home/carlos/colmap_test/sequential/logs/
```

Processed image list:

```text
/home/carlos/colmap_test/sequential/processed_images.txt
```

---

## Restarting from zero

This deletes the COLMAP database, previous sparse models, PLY output, processed image list, and JSON stats log. It does **not** delete your images.

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_test/sequential \
  --image-path /home/carlos/colmap_test/images \
  --reset
```

Or with config:

```bash
./colmap_live.sh --config config.env --reset
```

---

## Quick recommended command for your current paths

From inside the downloaded `colmap_live_pipeline` folder:

```bash
chmod +x colmap_live.sh
chmod +x run_example_carlos_paths.sh

./run_example_carlos_paths.sh --reset
```

For live incoming images:

```bash
./run_example_carlos_paths.sh --watch
```

To inspect the JSON log:

```bash
cat /home/carlos/colmap_test/sequential/pointcloud_log.json
```

Or pretty-print it:

```bash
python3 -m json.tool /home/carlos/colmap_test/sequential/pointcloud_log.json
```
