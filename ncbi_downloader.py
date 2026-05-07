#!/usr/bin/env python3

from pathlib import Path
import argparse
import sqlite3 
import hashlib

from tqdm import tqdm
import pandas as pd
import requests


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", type=str, required=True, help="NCBI summary tsv (i.e. https://ftp.ncbi.nlm.nih.gov/genomes/refseq/archaea/assembly_summary.txt)")
    parser.add_argument("--query", type=str, required=True, help="sqlite3 query to select data for download")
    parser.add_argument("--preview", action="store_true", help="Preview query results without downloading")
    parser.add_argument("--outdir", type=Path, default=Path.cwd(), help="Path to output dir")
    parser.add_argument("--file_type", type=str, default="_genomic.fna.gz", help="FTP suffix (i.e. '_genomic.fna.gz)")
    return parser.parse_args()


def validate_file(ftp, reference, md5local):
    source = requests.get(f"{ftp}/md5checksums.txt")

    with open("tmp.txt", "wb") as tmp:
        tmp.write(source.content)
    
    df = pd.read_csv("tmp.txt", sep=r'\s+', header=None)
    filtered_df = df[df[1] == f"./{reference}"]
    return filtered_df[0].values[0] == md5local


def main():
    args = parse_args()
    outdir = args.outdir
    outdir.mkdir(exist_ok=True, parents=True)

    ncbi = requests.get(args.summary)

    # TODO: check if summary file attempting to download is the one existing on disk

    summary = outdir / "summary.tsv"
    with open(summary, "wb") as f:
        f.write(ncbi.content) 

    df = pd.read_csv(summary, sep='\t', skiprows=1)
    conn = sqlite3.connect(outdir / "summary.db")
    df.to_sql("summary", conn, if_exists="replace", index=False)
    result = pd.read_sql_query(args.query, conn)

    if args.preview:
        print(f"Query will return {len(result)} items")
        return

    data = outdir / "data"
    data.mkdir(exist_ok=True, parents=True)
    
    for _, row in tqdm(result.iterrows(), total=len(result), desc="Progress"):
        ftp = row["ftp_path"]
        target = ftp.split("/")[-2]
        link = f"{ftp}{target}{args.file_type}"
        response = requests.get(link, timeout=120)
        outfile = data / f"{target}{args.file_type}"

        md5local = hashlib.md5(response.content).hexdigest()

        if validate_file(ftp, f"{target}{args.file_type}", md5local):
            with open(outfile, "wb") as out_f:
                out_f.write(response.content)
        else:
            print(f"{ftp} md5 mismatch, skipping...")

        
if __name__ == "__main__":
    main()
