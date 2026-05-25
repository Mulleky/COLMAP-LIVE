# COLMAP Live Pipeline

This repository contains small scripts for processing images with COLMAP as they arrive, keeping a sparse model updated, logging reconstruction/resource metrics, and plotting the resulting run data.

It is a practical approximation of online/incremental SfM. It is not true real-time SLAM, but it is useful for camera streams, image folders that grow over time, and experiments where you want repeated sparse-model updates.

## Contents

```text
colmap_live_pipeline/
├── colmap_live.sh              Main COLMAP live/incremental pipeline
├── config.env                  Example configuration file
├── monitor_system_usage.py     CPU/RAM/NVIDIA GPU usage logger
├── plot_colmap_run_metrics.py  Plot reconstruction and resource metrics
├── colmap_ros2_cam.sh          Optional ROS 2 camera image capture helper
└── README.md
```

## Requirements

- COLMAP available in `PATH`, or pass `--colmap-bin /path/to/colmap`.
- Python 3.
- `matplotlib` for plotting.
- Optional: `nvidia-smi` and a COLMAP build with CUDA support for NVIDIA GPU SIFT extraction/matching.

## Workspace Layout

You provide an image folder and a separate workspace folder. The pipeline writes all COLMAP outputs, logs, and metrics into the workspace.

```text
your_project/
├── images/
│   ├── frame_0001.jpg
│   ├── frame_0002.jpg
│   └── ...
└── workspace/
    ├── database.db
    ├── processed_images.txt
    ├── pointcloud_log.json
    ├── resource_usage_log.json
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

## What `colmap_live.sh` Does

For each new image:

```text
extract features for the new image
match features in the accumulated database
initialize a sparse model if none exists yet
otherwise register the image into the live model
triangulate new points
optionally run bundle adjustment
optionally rebuild from the database if incremental triangulation fails
export sparse_live.ply
append reconstruction stats to pointcloud_log.json
```

In parallel, the script can run `monitor_system_usage.py` and log CPU, RAM, and NVIDIA GPU usage to `resource_usage_log.json`.

The first image normally cannot produce a 3D sparse cloud. You need multiple images with overlap and baseline before COLMAP can initialize a model.

## Quick Start

Make the scripts executable once:

```bash
chmod +x colmap_live.sh
chmod +x monitor_system_usage.py
chmod +x plot_colmap_run_metrics.py
```

Run once on an existing image folder:

```bash
./colmap_live.sh \
  --workspace /path/to/project/workspace \
  --image-path /path/to/project/images
```

Start fresh:

```bash
./colmap_live.sh \
  --workspace /path/to/project/workspace \
  --image-path /path/to/project/images \
  --reset
```

Watch for newly arriving images:

```bash
./colmap_live.sh \
  --workspace /path/to/project/workspace \
  --image-path /path/to/project/images \
  --watch
```

Stop watch mode with `Ctrl+C`.

## Local Usage On This Machine

For the current local workspace in this folder, use:

```bash
cd /home/carlos/colmap_live_pipeline
```

Run the COLMAP live pipeline on the local `images/` folder and write outputs to `sequential/`:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_live_pipeline/sequential \
  --image-path /home/carlos/colmap_live_pipeline/images
```

Start fresh with:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_live_pipeline/sequential \
  --image-path /home/carlos/colmap_live_pipeline/images \
  --reset
```

Watch for new images from the ROS/camera capture script:

```bash
./colmap_live.sh \
  --workspace /home/carlos/colmap_live_pipeline/sequential \
  --image-path /home/carlos/colmap_live_pipeline/images \
  --watch
```

The local JSON logs are:

```text
/home/carlos/colmap_live_pipeline/sequential/pointcloud_log.json
/home/carlos/colmap_live_pipeline/sequential/resource_usage_log.json
```

The local sparse PLY output is:

```text
/home/carlos/colmap_live_pipeline/sequential/sparse_live.ply
```

## Run With `config.env`

Edit `config.env`:

```bash
nano config.env
```

Set the two required paths:

```bash
WORKSPACE="/path/to/project/workspace"
IMAGE_PATH="/path/to/project/images"
```

Then run:

```bash
./colmap_live.sh --config config.env
```

Common variants:

```bash
./colmap_live.sh --config config.env --reset
./colmap_live.sh --config config.env --watch
```

## Important Options

### Matching

For ordered image streams such as video frames or robot/camera sequences:

```bash
--matcher sequential
--sequential-overlap 10
```

For small unordered image collections:

```bash
--matcher exhaustive
```

### Camera Model

Common choices:

```bash
--camera-model PINHOLE
--camera-model SIMPLE_PINHOLE
--camera-model SIMPLE_RADIAL
--camera-model OPENCV
```

If all images come from the same physical camera, keep:

```bash
--single-camera 1
```

### GPU SIFT

COLMAP exposes GPU acceleration for SIFT feature extraction and matching:

```bash
--use-gpu 1
--gpu-index -1
```

`GPU_INDEX=-1` lets COLMAP choose automatically. Use CPU-only SIFT with:

```bash
--use-gpu 0
```

This flag does not force every COLMAP step onto the GPU. Mapping, triangulation, and bundle adjustment do not use this same script-level GPU switch.

### Resource Monitoring

Resource monitoring is enabled by default:

```bash
LOG_RESOURCES="1"
RESOURCE_SAMPLE_SECONDS="1"
```

Disable it:

```bash
./colmap_live.sh --config config.env --no-resource-monitor
```

Choose a different resource log path or sample rate:

```bash
./colmap_live.sh \
  --config config.env \
  --resource-json /path/to/project/workspace/resource_usage_log.json \
  --resource-sample-seconds 2
```

If `nvidia-smi` is unavailable or no NVIDIA GPU is detected, CPU/RAM samples are still logged and GPU fields are written as `null`.

### Rebuild Fallback

The incremental update path can sometimes get stuck with a weak sparse model. If `point_triangulator` fails or produces a degraded model, the script can run a full COLMAP `mapper` rebuild from the accumulated database and replace `sparse_live` with the best rebuilt model.

This fallback is enabled by default:

```bash
REBUILD_ON_TRIANGULATION_FAILURE="1"
```

Disable it:

```bash
./colmap_live.sh --config config.env --no-rebuild-fallback
```

### Other Useful Flags

Skip bundle adjustment for speed:

```bash
--no-ba
```

Disable PLY export:

```bash
--no-ply
```

Disable reconstruction JSON stats:

```bash
--no-stats
```

Use custom output paths:

```bash
--database-path /path/to/workspace/database.db
--live-model-path /path/to/workspace/sparse_live
--output-ply /path/to/workspace/sparse_live.ply
--processed-list /path/to/workspace/processed_images.txt
--stats-json /path/to/workspace/pointcloud_log.json
```

## Metrics JSON Files

### Reconstruction Metrics

`pointcloud_log.json` is a JSON array with one record per initialized, updated, or rebuilt sparse model.

Important fields:

```text
counts.sparse_3d_points
counts.registered_images_in_sparse_model
counts.processed_images_including_trigger
quality_summary.mean_track_length
quality_summary.mean_observations_per_registered_image
```

### Resource Metrics

`resource_usage_log.json` is a JSON array of time samples.

Important fields:

```text
elapsed_seconds
cpu_percent
memory_percent
gpu_utilization_percent
gpu_memory_utilization_percent
gpu_memory_used_mib
```

`memory_percent` is system RAM usage. `gpu_memory_utilization_percent` is NVIDIA GPU VRAM usage.

## Plot Metrics

By default on this machine, `plot_colmap_run_metrics.py` reads:

```python
POINTCLOUD_JSON = Path("/home/carlos/colmap_live_pipeline/sequential/pointcloud_log.json")
RESOURCE_JSON = POINTCLOUD_JSON.parent / "resource_usage_log.json"
OUTPUT_DIR = POINTCLOUD_JSON.parent / "run_metric_plots"
```

Run:

```bash
cd /home/carlos/colmap_live_pipeline
python3 plot_colmap_run_metrics.py
```

Plots are saved to:

```text
/home/carlos/colmap_live_pipeline/sequential/run_metric_plots
```

The plotter skips missing data gracefully, for example if no resource log exists or no GPU values were recorded.

Generated plots can include:

```text
sparse_point_count.png
processed_vs_registered_images.png
mean_track_length.png
mean_observations_per_image.png
cpu_usage_percent.png
memory_usage_percent.png
gpu_usage_percent.png
gpu_memory_usage_percent.png
```

## ROS 2 Image Capture Helper

`colmap_ros2_cam.sh` is an optional helper for saving images from a ROS 2 camera topic into a folder that `colmap_live.sh` can watch.

Example:

```bash
./colmap_ros2_cam.sh \
  -i /path/to/project/images \
  -v /dev/video0 \
  -h 1.0
```

Then run the live pipeline against the same image folder:

```bash
./colmap_live.sh \
  --workspace /path/to/project/workspace \
  --image-path /path/to/project/images \
  --watch
```

## Resetting

`--reset` deletes the COLMAP database, sparse models, PLY output, processed image list, stats JSON, resource JSON, and temporary folders inside the workspace. It does not delete your images.

```bash
./colmap_live.sh --config config.env --reset
```

## Troubleshooting

If `sparse_live.ply` is poor but a full COLMAP GUI reconstruction works well, the live incremental model may have initialized too early or become weak. Keep the rebuild fallback enabled so the script can recover by running `mapper` over the accumulated database.

If GPU plots are empty, check that:

- Resource monitoring was enabled.
- `nvidia-smi` works in the terminal.
- Your COLMAP build actually uses CUDA for SIFT extraction/matching.

If no sparse model appears after the first few images, add more overlapping images or increase sequential overlap:

```bash
--sequential-overlap 20
```
