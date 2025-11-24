#!/usr/bin/env python3

import argparse
from pathlib import Path


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
        help='Path to assembly dir (outdir)'
    )
    parser.add_argument(
        '-s', '--file_suffix',
        type=str,
        required=True,
        help='"x" is a placeholder to differentiate between read numbers. Example suffix: "_x.fastq.gz" or "x.fq"'
    )
    return parser.parse_args()


class ReadError(Exception):
    pass


def generate_manifest(input_dir: Path, output: Path, suffix: str):
    if not input_dir.is_dir():
        raise NotADirectoryError(f'Input path must be a directory -> {input_dir}')

    samples = sorted(input_dir.iterdir())

    if suffix.count('x') != 1:
        raise ValueError('File suffix must contain exactly one "x" placeholder')
    
    r1 = suffix.replace('x', '1')
    r2 = suffix.replace('x', '2')

    with open(output, 'w') as out_f:
        out_f.write('ID,R1,R2\n')

        for sample in samples:
            if not sample.is_dir():
                continue

            reads = sorted(sample.iterdir())

            read_1 = None
            read_2 = None
            
            for read in reads:
                name = read.name
                if name.endswith(r1):
                    read_1 = read
                elif name.endswith(r2):
                    read_2 = read
                else:
                    continue

            if read_1 is None or read_2 is None:
                raise ReadError(f'Missing reads in sample {sample.name}, check sample dir')
            
            out_f.write(f'{sample.name},{read_1},{read_2}\n')


def main():
    args = parse_args()
    generate_manifest(args.input, args.output, args.file_suffix)


if __name__ == '__main__':
    main()
