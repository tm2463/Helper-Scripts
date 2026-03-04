#!/usr/bin/bash

MGEMS_DIR="$1"
CLOSE="$2"
SET="$3"
OUTDIR="$4"
#make this generic
C_ACCESSION=("SRR8435179" "ERR068275" "ERR069630" "SRR7190004" "SRR8725470")
D_ACCESSION=("SRR8879297" "SRR8879298" "SRR8879299" "SRR7190004" "SRR8726518")

mkdir -p $OUTDIR
mkdir -p $OUTDIR/$CLOSE
> ${OUTDIR}/${CLOSE}/${SET}.csv

for bin in ${MGEMS_DIR}/*.fastq.gz; do
    for id in "${D_ACCESSION[@]}"; do
        id_count=$(zcat "$bin" | grep -c "$id")
        echo "${bin},${id},${id_count}" >> ${OUTDIR}/${CLOSE}/${SET}.csv
    done
done
