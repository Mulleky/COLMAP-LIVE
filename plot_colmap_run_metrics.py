#!/usr/bin/env python3

import json
from pathlib import Path

import matplotlib.pyplot as plt


# =========================
# EDIT THESE PATHS
# =========================
POINTCLOUD_JSON = Path("/home/carlos/colmap_live_pipeline/sequential/pointcloud_log.json")
RESOURCE_JSON = POINTCLOUD_JSON.parent / "resource_usage_log.json"

# Optional: where plots will be saved
OUTPUT_DIR = POINTCLOUD_JSON.parent / "run_metric_plots"


def safe_get(record, keys, default=None):
    value = record
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def load_json_log(json_path, label):
    if not json_path.exists():
        raise FileNotFoundError(f"{label} JSON file not found: {json_path}")

    with json_path.open("r") as f:
        data = json.load(f)

    if not isinstance(data, list):
        raise ValueError(f"Expected the {label} JSON file to contain a list of records.")

    if len(data) == 0:
        raise ValueError(f"{label} JSON log is empty.")

    return data


def extract_pointcloud_series(data):
    point_cloud_ids = []
    processed_images = []
    registered_images = []
    sparse_points = []
    mean_observations = []
    mean_track_lengths = []

    for i, record in enumerate(data):
        point_cloud_ids.append(record.get("point_cloud_id", i + 1))
        processed_images.append(
            safe_get(record, ["counts", "processed_images_including_trigger"], 0)
        )
        registered_images.append(
            safe_get(record, ["counts", "registered_images_in_sparse_model"], 0)
        )
        sparse_points.append(safe_get(record, ["counts", "sparse_3d_points"], 0))
        mean_observations.append(
            safe_get(record, ["quality_summary", "mean_observations_per_registered_image"])
        )
        mean_track_lengths.append(
            safe_get(record, ["quality_summary", "mean_track_length"])
        )

    return {
        "point_cloud_ids": point_cloud_ids,
        "processed_images": processed_images,
        "registered_images": registered_images,
        "sparse_points": sparse_points,
        "mean_observations": mean_observations,
        "mean_track_lengths": mean_track_lengths,
    }


def extract_resource_series(data):
    return {
        "elapsed_seconds": [record.get("elapsed_seconds") for record in data],
        "cpu_percent": [record.get("cpu_percent") for record in data],
        "memory_percent": [record.get("memory_percent") for record in data],
        "gpu_percent": [record.get("gpu_utilization_percent") for record in data],
        "gpu_memory_percent": [
            record.get("gpu_memory_utilization_percent") for record in data
        ],
        "gpu_memory_used_mib": [record.get("gpu_memory_used_mib") for record in data],
    }


def valid_xy(x_values, y_values):
    x_valid = []
    y_valid = []

    for x, y in zip(x_values, y_values):
        if x is not None and y is not None:
            x_valid.append(x)
            y_valid.append(y)

    return x_valid, y_valid


def plot_line(x, y, title, xlabel, ylabel, output_path):
    plt.figure(figsize=(9, 5))
    plt.plot(x, y, marker="o")
    plt.title(title)
    plt.xlabel(xlabel)
    plt.ylabel(ylabel)
    plt.grid(True)
    plt.tight_layout()
    plt.savefig(output_path, dpi=200)
    plt.show()


def plot_two_lines(x, y1, y2, label1, label2, title, xlabel, ylabel, output_path):
    plt.figure(figsize=(9, 5))
    plt.plot(x, y1, marker="o", label=label1)
    plt.plot(x, y2, marker="o", label=label2)
    plt.title(title)
    plt.xlabel(xlabel)
    plt.ylabel(ylabel)
    plt.grid(True)
    plt.legend()
    plt.tight_layout()
    plt.savefig(output_path, dpi=200)
    plt.show()


def plot_pointcloud_metrics():
    data = load_json_log(POINTCLOUD_JSON, "point-cloud")
    series = extract_pointcloud_series(data)
    x = series["point_cloud_ids"]

    print(f"Loaded {len(data)} point cloud records from:")
    print(POINTCLOUD_JSON)
    print()

    latest = data[-1]
    print("Latest point-cloud record:")
    print(f"  Point cloud ID: {latest.get('point_cloud_id')}")
    print(f"  Trigger image: {latest.get('trigger_image')}")
    print(f"  Sparse 3D points: {safe_get(latest, ['counts', 'sparse_3d_points'])}")
    print(f"  Registered images: {safe_get(latest, ['counts', 'registered_images_in_sparse_model'])}")
    print(f"  Processed images: {safe_get(latest, ['counts', 'processed_images_including_trigger'])}")
    print()

    plot_line(
        x=x,
        y=series["sparse_points"],
        title="Sparse 3D Point Count Over Time",
        xlabel="Point Cloud Snapshot ID",
        ylabel="Sparse 3D Points",
        output_path=OUTPUT_DIR / "sparse_point_count.png",
    )

    plot_two_lines(
        x=x,
        y1=series["processed_images"],
        y2=series["registered_images"],
        label1="Processed Images",
        label2="Registered Images in Sparse Model",
        title="Processed vs Registered Images",
        xlabel="Point Cloud Snapshot ID",
        ylabel="Image Count",
        output_path=OUTPUT_DIR / "processed_vs_registered_images.png",
    )

    valid_track_x, valid_track_y = valid_xy(x, series["mean_track_lengths"])
    if valid_track_y:
        plot_line(
            x=valid_track_x,
            y=valid_track_y,
            title="Mean Track Length Over Time",
            xlabel="Point Cloud Snapshot ID",
            ylabel="Mean Track Length",
            output_path=OUTPUT_DIR / "mean_track_length.png",
        )
    else:
        print("Skipping mean track length plot because no values were found.")

    valid_obs_x, valid_obs_y = valid_xy(x, series["mean_observations"])
    if valid_obs_y:
        plot_line(
            x=valid_obs_x,
            y=valid_obs_y,
            title="Mean Observations per Registered Image",
            xlabel="Point Cloud Snapshot ID",
            ylabel="Mean Observations per Registered Image",
            output_path=OUTPUT_DIR / "mean_observations_per_image.png",
        )
    else:
        print("Skipping mean observations plot because no values were found.")


def plot_resource_metrics():
    if not RESOURCE_JSON.exists():
        print(f"Skipping resource plots because no resource JSON was found: {RESOURCE_JSON}")
        return

    data = load_json_log(RESOURCE_JSON, "resource")
    series = extract_resource_series(data)
    elapsed = series["elapsed_seconds"]

    print(f"Loaded {len(data)} resource usage samples from:")
    print(RESOURCE_JSON)
    print()

    cpu_x, cpu_y = valid_xy(elapsed, series["cpu_percent"])
    if cpu_y:
        plot_line(
            x=cpu_x,
            y=cpu_y,
            title="CPU Usage Over Time",
            xlabel="Elapsed Seconds",
            ylabel="CPU Usage (%)",
            output_path=OUTPUT_DIR / "cpu_usage_percent.png",
        )
    else:
        print("Skipping CPU usage plot because no CPU values were found.")

    mem_x, mem_y = valid_xy(elapsed, series["memory_percent"])
    if mem_y:
        plot_line(
            x=mem_x,
            y=mem_y,
            title="Memory Usage Over Time",
            xlabel="Elapsed Seconds",
            ylabel="Memory Usage (%)",
            output_path=OUTPUT_DIR / "memory_usage_percent.png",
        )
    else:
        print("Skipping memory usage plot because no memory values were found.")

    gpu_x, gpu_y = valid_xy(elapsed, series["gpu_percent"])
    if gpu_y:
        plot_line(
            x=gpu_x,
            y=gpu_y,
            title="GPU Usage Over Time",
            xlabel="Elapsed Seconds",
            ylabel="GPU Usage (%)",
            output_path=OUTPUT_DIR / "gpu_usage_percent.png",
        )
    else:
        print("Skipping GPU usage plot because no GPU values were found.")

    gpu_mem_x, gpu_mem_y = valid_xy(elapsed, series["gpu_memory_percent"])
    if gpu_mem_y:
        plot_line(
            x=gpu_mem_x,
            y=gpu_mem_y,
            title="GPU Memory Usage Over Time",
            xlabel="Elapsed Seconds",
            ylabel="GPU Memory Usage (%)",
            output_path=OUTPUT_DIR / "gpu_memory_usage_percent.png",
        )
        return

    gpu_mem_used_x, gpu_mem_used_y = valid_xy(elapsed, series["gpu_memory_used_mib"])
    if gpu_mem_used_y:
        plot_line(
            x=gpu_mem_used_x,
            y=gpu_mem_used_y,
            title="GPU Memory Used Over Time",
            xlabel="Elapsed Seconds",
            ylabel="GPU Memory Used (MiB)",
            output_path=OUTPUT_DIR / "gpu_memory_used_mib.png",
        )
    else:
        print("Skipping GPU memory plot because no GPU memory values were found.")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    plot_pointcloud_metrics()
    plot_resource_metrics()

    print("Plots saved to:")
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
