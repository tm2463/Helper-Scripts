#!/usr/bin/env python3

import argparse
from pathlib import Path
import sys
import logging
import gzip
import csv
import os


def setup_logging(log_file: str = "fastq_manifest.log"):
    logging.basicConfig(
        level=logging.INFO,
        handlers=[logging.StreamHandler(), logging.FileHandler(log_file, mode="w")],
        format="%(asctime)s - %(levelname)s - %(message)s",
    )
    logging.info("Logging initialized.")


def parse_args():
    parser = argparse.ArgumentParser(
        description='Illumina mainfest generator'
    )
    parser.add_argument(
        '-i','--input',
        type=Path,
        required=True,
        help='Path to reads dir'
    )
    parser.add_argument(
        '-o', '--output',
        type=Path,
        required=True,
        help='Path to output directory'
    )
    parser.add_argument(
        '-v', '--fastq_validation',
        choices=['strict', 'relaxed'],
        default='relaxed',
        help='Switch between FASTQ validation modes. Strict mode validates each file is in standard FASTQ format (WARNING: strict mode is expensive, particularly for large manifests). Relaxed mode validates via file extension only (e.g. ".fq.gz").'
    )
    parser.add_argument(
        '-d', '--max_depth',
        type=int,
        default=0,
        help='Max depth to scan for FASTQ files. Default = 0'
    )
    return parser.parse_args()


def infer_read_pairs(input_dir: Path) -> list[tuple]:
    reads = []
    previous = None
    for read in sorted(input_dir.iterdir()):
        if read.is_dir():
            continue

        read = Path(read)
        name = read.name
        parent = read.parent

        if previous is None:
            previous = name
        else:
            if len(previous) == len(name):
                suffix = ''.join(read.suffixes)
                if sum(c1!=c2 for c1, c2 in zip(previous, name)) == 1: # read pair names should only differ by 1 character
                    for n, (d1, d2) in enumerate(zip(previous, name)):
                        if d1 in {'1', '2'} and d2 in {'1', '2'} and d1!=d2: # validate differing characters are either '1' or '2'
                            base = name[:n] + '@' # placeholder character
                            remain = ''
                            if len(name[n+1:]) > len(suffix): # handle case where sample has further characters after placeholder before prefix
                                remain = name[n+1:-len(suffix)]
                            sample = parent / (base + remain)
                            reads.append((sample, suffix))
                            break
                        
        previous = name
    return reads


def is_gzip(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"\x1f\x8b"
    except OSError:
        return False


def is_fastq(path: Path) -> bool:
    opener = gzip.open if is_gzip(path) else open
    try:
        with opener(path, "rb") as f:
            line1 = f.readline()
            f.readline()
            line3 = f.readline()
        return line1.startswith(b"@") and line3.startswith(b"+")
    except OSError:
        return False
    

def validate_reads(read, mode):
    if mode == 'strict':
        fastq = is_fastq(read)
        if not fastq:
            return False
    elif mode == 'relaxed':
        if not read.endswith(['.fq', '.fq.gz', '.fastq', '.fastq.gz']):
            return False


def main():
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)

    setup_logging(log_file=args.output.parent / "fastq_manifest.log")
    logging.info(f'Manifest generator input: {args.input}')
    logging.info(f'Manifest generator in {args.fastq_validation} mode')
    logging.info(f'Max depth set to {args.max_depth}')

    # Validate params
    if not (args.input).is_dir():
        logging.error(f'Input path must be a directory -> {args.input}')
        sys.exit(1)

    with open(args.output / "manifest.csv", 'w') as f:
        writer = csv.writer(f)
        writer.writerow(['ID', 'R1', 'R2'])

        counter = 0

        base_path = os.path.abspath(args.input)
        base_depth = base_path.count(os.sep)

        for (root, dirs, files) in os.walk(args.input, topdown=True):
            depth = root.count(os.sep) - base_depth
            if depth >= args.max_depth:
                dirs[:] = []
            
            for paths, prefix in infer_read_pairs(Path(root)):
                path = Path(paths)
                stem = path.stem
                base = path.parent

                read_1 = stem.replace('@', '1') + prefix
                read_2 = stem.replace('@', '2') + prefix

                R1 = base / read_1
                R2 = base / read_2
                ID = stem.replace('@', '')

                if ID.endswith('R'):
                    ID = ID[:-1]
                if ID.endswith('_'):
                    ID = ID[:-1]

                # sanity check
                if not R1.exists():
                    logging.warning(f'Skipping {ID} -> Error occured, check file path: {R1}')
                    continue
                if not R2.exists():
                    logging.warning(f'Skipping {ID} -> Error occured, check file path: {R2}')
                    continue

                # validate reads
                if validate_reads(R1, args.fastq_validation) is False:
                    logging.warning(f"{R1} failed FASTQ validation")
                    continue
                if validate_reads(R2, args.fastq_validation) is False:
                    logging.warning(f"{R2} failed FASTQ validation")
                    continue

                writer.writerow([ID, str(R1), str(R2)])
                counter += 1

    logging.info(f'Finished writing manifest to {args.output / "manifest.csv"}')
    logging.info(f'Manifest contains {counter} read pairs')

        
if __name__ == '__main__':
    main()
