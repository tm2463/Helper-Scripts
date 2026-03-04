#!/usr/bin/env python3

import matplotlib.pyplot as plt
import pandas as pd

from pathlib import Path
import argparse

def parse_args():
    parser = argparse.ArgumentParser(
        description='Compares expected vs observed binned read counts'
    )
    parser.add_argument(
        '-c','--read_counts',
        type=Path,
        required=True,
        help='Path to close reads dir'
    )
    parser.add_argument(
        '-p','--community_proportions',
        type=Path,
        required=True,
        help='Path to close community proportion tsv'
    )
    parser.add_argument(
        '-o','--outdir',
        type=Path,
        required=True,
        help='Path to distant reads dir'
    )
    return parser.parse_args()

def parse_community_proportion(tsv_file: Path) -> pd.DataFrame:
    df = pd.read_csv(tsv_file, sep='\t', comment='#', header=0)
    df = df.set_index('set')
    return df

def bar_chart(df, outdir, label):
    clusters = df["cluster"].unique()
    num_clusters = len(clusters)

    fig, axes = plt.subplots(1, num_clusters, figsize=(num_clusters * 5, 5))
    for ax, cluster in zip(axes, clusters):
        sub_df = df[df["cluster"] == cluster]
        accessions = sub_df["accession"]
        read_counts = sub_df["read_count"]
        expected_counts = sub_df["expected_counts"]

        width = 0.35
        x = range(len(accessions))
        ax.bar(
            [i - width/2 for i in x], 
            read_counts, 
            width=width, 
            label="Observed", 
            color="skyblue"
        )
        ax.bar(
            [i + width/2 for i in x], 
            expected_counts, 
            width=width, 
            label="Expected", 
            color="salmon"
        )
        ax.set_xticks(x)
        ax.set_xticklabels(accessions, rotation=45, ha="right")
        ax.set_title(cluster)
        ax.set_xlabel("Accession")
        ax.set_ylabel("Read Count")

    axes[0].legend(loc="upper left")
    plt.tight_layout()
    plt.savefig(outdir / f"{label}.png")
    plt.close(fig)

def main():
    args = parse_args()
    args.outdir.parent.mkdir(parents=True, exist_ok=True)

    proportions = parse_community_proportion(args.community_proportions)
    sets = sorted(args.read_counts.iterdir())

    cache = None
    for SET in sets:
        set_id = SET.stem
        label = set_id[-1]

        df = pd.read_csv(SET, names=['cluster', 'accession', 'read_count'])
        df["cluster"] = df["cluster"].apply(lambda x: Path(x).stem)
        df = df[~df["cluster"].str.contains("_2")]

        if set_id == 'SET_A':
            df["cache"] = df["read_count"] * 5
            cache = df[["cluster","accession","cache"]]
        else:
            df = df.merge(cache, on=["cluster", "accession"], how="left")
            cluster_proportions = proportions.loc[label]
            df["proportion"] = df["accession"].map(cluster_proportions)
            df["expected_counts"] = df["cache"] * (df["proportion"] / 100)
            df["departure"] = df["expected_counts"] - df["read_count"]
            df = df.drop(columns=['cache', 'proportion'])
            bar_chart(df, args.outdir, label)

if __name__ == "__main__":
    main()
