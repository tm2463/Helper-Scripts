#!/usr/bin/env python3

"""
This script calculates compute resources and number of files generated for each process of a Nextflow pipeline
Use it to diagnose any issues, such as which processes generate a large number of files, or assess how much compute each process requires
"""

from collections import defaultdict
from pathlib import Path
import glob
import os
import argparse

from tqdm import tqdm
import pandas as pd
import matplotlib.pyplot as plt


class FileCounter:
    """
    Take:
        path: Path to Nextflow pipeline work dir
        df: Cleaned execution trace
        outdir: Path to output directory to save results

    Return:
        Saves a figure to outdir showing the number of files per process

    Usage:
        FileCounter(<path/to/work>, <cleaned_execution_trace_df>).run(<path/to/outdir>)
    """
    def __init__(self, path, df):
        self.path = path
        self.df = df

    @staticmethod
    def _list_files_recursive(path, files=None):
        """
        Recursively find files in a directory and its subdirectories
        """
        if files is None:
            files = []

        for entry in os.listdir(path):
            full_path = os.path.join(path, entry)
            if os.path.isdir(full_path):
                FileCounter._list_files_recursive(full_path, files)
            else:
                files.append(full_path)

        return files
    
    def _count_files(self):
        """
        Count the number of files in each process's work directory
        """
        _df = self.df[["hash", "name"]]
        process_dict = _df.set_index("hash")["name"].to_dict()

        count_dict = defaultdict(int)
        for hash, process in tqdm(process_dict.items()):
            partial = ''.join([str(self.path), '/', hash, '*'])
            work_dir = (glob.glob(partial))

            if len(work_dir) != 1:
                print(f"WARNING: Glob matched {len(work_dir)} work directories")
                print(f"{[print(d) for d in work_dir]}")
                continue

            for dir in work_dir:
                files = FileCounter._list_files_recursive(dir)
                count_dict[process] += len(files)

        return count_dict

    def _plot_file_counts(self, count_dict, outdir):
        """
        Plot the number of files per process and save the figure to outdir
        """
        total = sum(count_dict.values())
        sorted_items = sorted(count_dict.items(), key=lambda x: x[1], reverse=True)
        processes, counts = zip(*sorted_items)

        fig, ax = plt.subplots(figsize=(10, 6))
        ax.bar(processes, counts)

        ax.text(
            0.5, 0.98,
            f"Total files: {total:,}",
            transform=ax.transAxes,
            ha="center",
            va="top"
        )

        plt.xticks(rotation=45, ha="right", fontsize=7)
        ax.set_xlabel("Process")
        ax.set_ylabel("File Count")
        ax.set_title("File Count per Process")
        plt.tight_layout()

        out_path = outdir / f"file_counts.png"
        plt.savefig(out_path, dpi=150)
        plt.close(fig)

    def run(self, outdir):
        """
        Callable function to count files per process and plot the results
        """
        count_dict = self._count_files()
        self._plot_file_counts(count_dict, outdir)


class AssessCompute:
    """
    Take:
        df: Cleaned execution trace
        outdir: Path to output directory to save results

    Return:
        Saves a figure to outdir showing the mean and standard deviation of runtime and memory usage per process

    Usage:
        AssessCompute(<cleaned_execution_trace_df>).run(<path/to/outdir>)
    """
    def __init__(self, df):
        self.df = df

    def _compute_stats(self):
        """
        Returns a DataFrame with the mean and standard deviation of runtime and memory usage per process
        """
        _df = self.df[["task_id", "name", "realtime", "peak_vmem"]]

        order = _df.groupby("name")["task_id"].min().sort_values()
        process_order = order.index.tolist()

        stats = _df.groupby("name").agg(
            realtime_mean=("realtime", "mean"),
            realtime_std=("realtime", "std"),
            peak_vmem_mean=("peak_vmem", "mean"),
            peak_vmem_std=("peak_vmem", "std")
        ).reindex(process_order).fillna(0)

        return stats

    def _plot_compute_stats(self, stats, outdir):
        """
        Plot the mean and standard deviation of runtime and memory usage per process
        """
        processes = stats.index.tolist()
        x = range(len(processes))

        fig, ax1 = plt.subplots(figsize=(12, 6))
        ax2 = ax1.twinx()

        bars1 = ax1.bar(
            [i - 0.2 for i in x], stats["realtime_mean"], width=0.4,
            label="Mean Realtime (s)", color="steelblue",
            yerr=stats["realtime_std"], capsize=3, error_kw={"ecolor": "steelblue", "alpha": 0.6}
        )
        bars2 = ax2.bar(
            [i + 0.2 for i in x], stats["peak_vmem_mean"], width=0.4,
            label="Max Peak vMem (MB)", color="coral",
            yerr=stats["peak_vmem_std"], capsize=3, error_kw={"ecolor": "coral", "alpha": 0.6}
        )

        ax1.set_ylim(bottom=0)
        ax2.set_ylim(bottom=0)
        ax1.set_xticks(x)
        ax1.set_xticklabels(processes, rotation=45, ha="right", fontsize=7)
        ax1.set_xlabel("Process")
        ax1.set_ylabel("Realtime (s)")
        ax2.set_ylabel("Peak vMem (MB)")
        ax1.tick_params(axis="y")
        ax2.tick_params(axis="y")

        ax1.legend([bars1, bars2], ["Mean Realtime (s)", "Mean Peak vMem (MB)"], loc="best")

        plt.title("Runtime and Memory per Process")
        plt.tight_layout()
        plt.savefig(outdir / "compute_stats.png", dpi=150)
        plt.close(fig)

    def run(self, outdir):
        """
        Callable function to compute and plot the mean and standard deviation of runtime and memory usage per process
        """
        stats = self._compute_stats()
        self._plot_compute_stats(stats, outdir)


def parse_args():
    parser = argparse.ArgumentParser(description="Quick and easy pipeline evaluation")
    parser.add_argument(
        "--execution_trace",
        type=Path,
        required=True,
        help="Path to Nextflow pipeline execution trace (e.g. /path/to/execution_trace.txt)"
    )
    parser.add_argument(
        "--work_dir",
        type=Path,
        required=True,
        help="Path to Nextflow pipeline work dir (e.g. /path/to/work)"
    )
    parser.add_argument(
        "-o", "--outdir",
        type=Path,
        default=Path.cwd(),
        help="Path to output directory to save results"
    )
    return parser.parse_args()


def validate_args(args):
    if not args.execution_trace.is_file():
        raise FileNotFoundError(f"Execution trace file not found: {args.execution_trace}")
    if not args.work_dir.is_dir():
        raise NotADirectoryError(f"Work directory not found: {args.work_dir}")
    args.outdir.mkdir(parents=True, exist_ok=True)


def parse_time_to_seconds(time_str):
    """
    Reformat execution trace time strings to seconds
    """
    parts = time_str.split(" ")

    seconds = 0
    for p in parts:
        if p[-2:] == "ms":
            seconds += float(p[:-2]) / 1000
        elif p[-1] == "s":
            seconds += float(p[:-1])
        elif p[-1] == "m":
            seconds += float(p[:-1]) * 60
        elif p[-1] == "h":
            seconds += float(p[:-1]) * 3600
        elif p[-1] == "d":
            seconds += float(p[:-1]) * 86400
        else:
            raise ValueError(f"Invalid time format: {time_str}")
    return seconds


def parse_memory_to_mb(mem_str):
    """
    Reformat execution trace memory strings to MB
    """
    parts = mem_str.split(" ")

    if parts[0] == "0":
        return 0.0

    if len(parts) != 2:
        raise ValueError(f"Invalid memory format: {mem_str}")

    val, unit = parts
    val = float(val)

    units_to_mb = {"KB": 1 / 1024, "MB": 1, "GB": 1024, "TB": 1024 * 1024}
    if unit not in units_to_mb:
        raise ValueError(f"Invalid memory unit: {unit}")

    return val * units_to_mb[unit]


def clean_execution_trace(df):
    """
    (1) Take the execution trace
    (2) Drop unnecessary columns
    (3) Reformat time and memory
    (4) Reformat name to be more readable
    """
    df = df[["task_id", "hash", "name", "status", "duration", "realtime", "peak_vmem"]]
    df = df[df["status"].isin(["COMPLETED", "CACHED"])]

    for t in ["duration", "realtime"]:
        df[t] = df[t].apply(parse_time_to_seconds)

    df["peak_vmem"] = df["peak_vmem"].apply(parse_memory_to_mb)

    parts = df["name"].str.split(" ").str[0].str.split(":")
    df["name"] = parts.str[-2] + ":" + parts.str[-1]
    return df


def main():
    args = parse_args()
    validate_args(args)

    df = pd.read_csv(args.execution_trace, sep='\t')
    df = clean_execution_trace(df)

    # Run file counting and compute assessment and save figures to output directory
    FileCounter(args.work_dir, df).run(args.outdir)
    AssessCompute(df).run(args.outdir)


if __name__ == "__main__":
    main()
