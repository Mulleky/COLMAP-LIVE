#!/usr/bin/env python3

import argparse
import json
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


RUNNING = True


def handle_signal(signum, frame):
    global RUNNING
    RUNNING = False


def read_proc_stat():
    with Path("/proc/stat").open("r") as f:
        first_line = f.readline().strip().split()

    values = [int(value) for value in first_line[1:]]
    idle = values[3] + values[4]
    total = sum(values)
    return idle, total


def cpu_percent(previous, current):
    previous_idle, previous_total = previous
    current_idle, current_total = current

    idle_delta = current_idle - previous_idle
    total_delta = current_total - previous_total

    if total_delta <= 0:
        return None

    return round(100.0 * (1.0 - idle_delta / total_delta), 2)


def memory_percent():
    values = {}
    with Path("/proc/meminfo").open("r") as f:
        for line in f:
            key, raw_value = line.split(":", 1)
            values[key] = int(raw_value.strip().split()[0])

    total = values.get("MemTotal")
    available = values.get("MemAvailable")

    if not total or available is None:
        return None

    used = total - available
    return round(100.0 * used / total, 2)


def query_gpu():
    if shutil.which("nvidia-smi") is None:
        return {
            "gpu_available": False,
            "gpu_name": None,
            "gpu_index": None,
            "gpu_utilization_percent": None,
            "gpu_memory_used_mib": None,
            "gpu_memory_total_mib": None,
            "gpu_memory_utilization_percent": None,
        }

    command = [
        "nvidia-smi",
        "--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
        "--format=csv,noheader,nounits",
    ]

    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        return {
            "gpu_available": False,
            "gpu_name": None,
            "gpu_index": None,
            "gpu_utilization_percent": None,
            "gpu_memory_used_mib": None,
            "gpu_memory_total_mib": None,
            "gpu_memory_utilization_percent": None,
        }

    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not lines:
        return {
            "gpu_available": False,
            "gpu_name": None,
            "gpu_index": None,
            "gpu_utilization_percent": None,
            "gpu_memory_used_mib": None,
            "gpu_memory_total_mib": None,
            "gpu_memory_utilization_percent": None,
        }

    parts = [part.strip() for part in lines[0].split(",", 4)]
    if len(parts) != 5:
        return {
            "gpu_available": False,
            "gpu_name": None,
            "gpu_index": None,
            "gpu_utilization_percent": None,
            "gpu_memory_used_mib": None,
            "gpu_memory_total_mib": None,
            "gpu_memory_utilization_percent": None,
        }

    gpu_index, gpu_name, gpu_util, mem_used, mem_total = parts

    try:
        gpu_util = float(gpu_util)
        mem_used = float(mem_used)
        mem_total = float(mem_total)
        mem_percent = round(100.0 * mem_used / mem_total, 2) if mem_total > 0 else None
    except ValueError:
        gpu_util = None
        mem_used = None
        mem_total = None
        mem_percent = None

    return {
        "gpu_available": True,
        "gpu_name": gpu_name,
        "gpu_index": int(gpu_index) if gpu_index.isdigit() else gpu_index,
        "gpu_utilization_percent": gpu_util,
        "gpu_memory_used_mib": mem_used,
        "gpu_memory_total_mib": mem_total,
        "gpu_memory_utilization_percent": mem_percent,
    }


def write_samples(output_json, samples):
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_json.write_text(json.dumps(samples, indent=2) + "\n")


def parse_args():
    parser = argparse.ArgumentParser(description="Log CPU, memory, and NVIDIA GPU usage to JSON.")
    parser.add_argument("--output-json", required=True, type=Path)
    parser.add_argument("--sample-seconds", type=float, default=1.0)
    parser.add_argument("--run-label", default=None)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.sample_seconds <= 0:
        raise ValueError("--sample-seconds must be greater than zero.")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    samples = []
    start_time = time.monotonic()
    previous_cpu = read_proc_stat()
    write_samples(args.output_json, samples)

    while RUNNING:
        time.sleep(args.sample_seconds)
        current_cpu = read_proc_stat()

        sample = {
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "elapsed_seconds": round(time.monotonic() - start_time, 3),
            "run_label": args.run_label,
            "cpu_percent": cpu_percent(previous_cpu, current_cpu),
            "memory_percent": memory_percent(),
        }
        sample.update(query_gpu())

        samples.append(sample)
        previous_cpu = current_cpu
        write_samples(args.output_json, samples)

    write_samples(args.output_json, samples)


if __name__ == "__main__":
    main()
