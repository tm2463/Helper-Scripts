#!/usr/bin/env bash

GRAPH_LIST=${1}

while read -r index; do
    OUTFILE=$(basename $index)
    metagraph transform -v -p 8 --to-fasta --primary-kmers -o ${OUTFILE}.contigs --disk-swap /tmp --mem-cap-gb 32 $index
done < $GRAPH_LIST

# Create a joint graph from all contigs in species index
ls *.contigs.fasta.gz | metagraph build -v -p 8 -k 31 --mode canonical -o joint --disk-swap /tmp --mem-cap-gb 32

# Extract primary contigs from the joint graph
metagraph transform -v -p 8 --to-fasta --primary-kmers -o joint_contigs_primary --disk-swap /tmp --mem-cap-gb 32 joint.dbg

# Joint primary graph from all contigs
metagraph build -v -p 8 -k 31 --mode primary -o combine --disk-swap /tmp --mem-cap-gb 32 joint_contigs_primary.fasta.gz

# clean up
rm joint*
rm *.contigs.fasta.gz
