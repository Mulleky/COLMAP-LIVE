#!/usr/bin/env python3

import json
from pathlib import Path

import matplotlib.pyplot as plt


# =========================
# EDIT THIS PATH
# =========================
JSON_PATH = Path("/home/carlos/colmap_test/sequential/pointcloud_log.json")

# Optional: where plots will be saved
OUTPUT_DIR = JSON_PATH.parent / "pointcloud_plots"


def safe_get(record, keys, default=None):
    """
    Safely read nested dictionary fields.

    Example:
        safe_get(record, ["counts", "sparse_3d_points"])
    """
    value = record
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def load_json_log(json_path):
    if not json_path.exists():
        raise FileNotFoundError(f"JSON file not found: {json_path}")

    with json_path.open("r") as f:
        data = json.load(f)

    if not isinstance(data, list):
        raise ValueError("Expected the JSON file to contain a list of records.")

    if len(data) == 0:
        raise ValueError("JSON log is empty.")

    return data


def extract_series(data):
    point_cloud_ids = []
    timestamps = []
    trigger_images = []

    processed_images = []
    registered_images = []
    sparse_points = []
    camera_counts = []

    mean_observations = []
    mean_track_lengths = []

    for i, record in enumerate(data):
        point_cloud_ids.append(record.get("point_cloud_id", i + 1))
        timestamps.append(record.get("timestamp_utc", ""))
        trigger_images.append(record.get("trigger_image", ""))

        processed_images.append(
            safe_get(record, ["counts", "processed_images_including_trigger"], 0)
        )
        registered_images.append(
            safe_get(record, ["counts", "registered_images_in_sparse_model"], 0)
        )
        sparse_points.append(
            safe_get(record, ["counts", "sparse_3d_points"], 0)
        )
        camera_counts.append(
            safe_get(record, ["counts", "cameras_in_sparse_model"], 0)
        )

        mean_observations.append(
            safe_get(record, ["quality_summary", "mean_observations_per_registered_image"], None)
        )
        mean_track_lengths.append(
            safe_get(record, ["quality_summary", "mean_track_length"], None)
        )

    return {
        "point_cloud_ids": point_cloud_ids,
        "timestamps": timestamps,
        "trigger_images": trigger_images,
        "processed_images": processed_images,
        "registered_images": registered_images,
        "sparse_points": sparse_points,
        "camera_counts": camera_counts,
        "mean_observations": mean_observations,
        "mean_track_lengths": mean_track_lengths,
    }


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


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    data = load_json_log(JSON_PATH)
    series = extract_series(data)

    x = series["point_cloud_ids"]

    print(f"Loaded {len(data)} point cloud records from:")
    print(JSON_PATH)
    print()

    print("Latest record:")
    latest = data[-1]
    print(f"  Point cloud ID: {latest.get('point_cloud_id')}")
    print(f"  Trigger image: {latest.get('trigger_image')}")
    print(f"  Sparse 3D points: {safe_get(latest, ['counts', 'sparse_3d_points'])}")
    print(f"  Registered images: {safe_get(latest, ['counts', 'registered_images_in_sparse_model'])}")
    print(f"  Processed images: {safe_get(latest, ['counts', 'processed_images_including_trigger'])}")
    print()

    # 1. Sparse point count over time
    plot_line(
        x=x,
        y=series["sparse_points"],
        title="Sparse 3D Point Count Over Time",
        xlabel="Point Cloud Snapshot ID",
        ylabel="Sparse 3D Points",
        output_path=OUTPUT_DIR / "sparse_point_count.png",
    )

    # 2. Registered images vs processed images
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

    # 3. Mean track length
    valid_track_x = []
    valid_track_y = []

    for xi, yi in zip(x, series["mean_track_lengths"]):
        if yi is not None:
            valid_track_x.append(xi)
            valid_track_y.append(yi)

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

    # 4. Mean observations per registered image
    valid_obs_x = []
    valid_obs_y = []

    for xi, yi in zip(x, series["mean_observations"]):
        if yi is not None:
            valid_obs_x.append(xi)
            valid_obs_y.append(yi)

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

    print(f"Plots saved to:")
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()