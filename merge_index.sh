#!/usr/bin/env bash

CONTIG_LIST=${1}
OUTDIR=${2}
THREADS=${3}
MEM=$((${4} - 2)) # Avoid memory issues

# Create sublist of primary contigs
while read -r line; do
    for file in $line/*; do
        realpath $file >> sublist.txt
    done
done < $CONTIG_LIST

# Create a joint graph from all contigs in species index
cat sublist.txt | metagraph build -v -p $THREADS -k 31 --mode canonical -o joint --disk-swap /tmp --mem-cap-gb $MEM

# Annotate joint graph
metagraph annotate -v -p $THREADS --disk-swap /tmp --mem-cap-gb $MEM -i joint.dbg --anno-filename --separately --threads-each 1 -o annotation $(cat sublist.txt)
