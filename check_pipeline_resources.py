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


class Time:
    def __init__(self, time_str):
        self.time_str = time_str

    def to_seconds(self):
        parts = self.time_str.split(" ")
        
        count = 0
        for p in parts:
            if p[-2:] == "ms":
                num = p[:-2]
                count += float(num) / 1000
            elif p[-1] == "s":
                num = p[:-1]
                count += float(num)
            elif p[-1] == "m":
                num = p[:-1]
                count += float(num) * 60
            elif p[-1] == "h":
                num = p[:-1]
                count += float(num) * 3600
            elif p[-1] == "d":
                num = p[:-1]
                count += float(num) * 86400
            else:
                raise ValueError(f"Invalid time format: {self.time_str}")
        return count


class Memory:
    def __init__(self, mem_str):
        self.mem_str = mem_str
        
    def to_mb(self):
        parts = self.mem_str.split(" ")

        if parts[0] == "0":
            return float(0.0)

        if len(parts) != 2:
            raise ValueError(f"Invalid memory format: {self.mem_str}")
        
        val, unit = parts
        val = float(val)

        if unit == "KB":
            return val / 1024
        elif unit == "MB":
            return val
        elif unit == "GB":
            return val * 1024
        elif unit == "TB":
            return val * 1024 * 1024
        else:
            raise ValueError(f"Invalid memory unit: {unit}")


class FileCounter:
    def __init__(self, path, df):
        self.path = path
        self.df = df

    @staticmethod
    def _list_files_recursive(path, files=None):
        if files is None:
            files = []

        for entry in os.listdir(path):
            full_path = os.path.join(path, entry)
            if os.path.isdir(full_path):
                FileCounter._list_files_recursive(full_path, files)
            else:
                files.append(full_path)

        return files
    
    def count_files(self):
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

    def plot_file_counts(self, count_dict, outdir):
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


class AssessCompute:
    def __init__(self, df):
        self.df = df

    def compute_stats(self):
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

    def plot_compute_stats(self, stats, outdir):
        processes = stats.index.tolist()
        x = range(len(processes))

        fig, ax1 = plt.subplots(figsize=(12, 6))
        ax2 = ax1.twinx()

        bars1 = ax1.bar(
            [i - 0.2 for i in x], stats["realtime_mean"], width=0.4,
            label="Mean Realtime (s)", color="steelblue",
            yerr=2 * stats["realtime_std"], capsize=3, error_kw={"ecolor": "steelblue", "alpha": 0.6}
        )
        bars2 = ax2.bar(
            [i + 0.2 for i in x], stats["peak_vmem_mean"], width=0.4,
            label="Max Peak vMem (MB)", color="coral",
            yerr=2 * stats["peak_vmem_std"], capsize=3, error_kw={"ecolor": "coral", "alpha": 0.6}
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


def clean_execution_trace(df):
    df = df[["task_id", "hash", "name", "status", "duration", "realtime", "peak_vmem"]]
    df = df[df["status"].isin(["COMPLETED", "CACHED"])]

    for t in ["duration", "realtime"]:
        df[t] = df[t].apply(lambda x: Time(x).to_seconds())

    df["peak_vmem"] = df["peak_vmem"].apply(lambda x: Memory(x).to_mb())
    
    parts = df["name"].str.split(" ").str[0].str.split(":")
    df["name"] = parts.str[-2] + ":" + parts.str[-1]
    return df


def main():
    args = parse_args()
    validate_args(args)

    df = pd.read_csv(args.execution_trace, sep='\t')
    df = clean_execution_trace(df)

    fc = FileCounter(args.work_dir, df)
    count_dict = fc.count_files()
    fc.plot_file_counts(count_dict, args.outdir)

    ac = AssessCompute(df)
    stats = ac.compute_stats()
    ac.plot_compute_stats(stats, args.outdir)


if __name__ == "__main__":
    main()
