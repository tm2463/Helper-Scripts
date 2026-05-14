#!/usr/bin/env bash

# module load copangraph/fc2d5ad
# module load samtools/1.21 
# module load bowtie2/2.5.1--py38he00c5e5_2

MANIFEST="$1"
OUTDIR="$2"

mkdir -p ${OUTDIR}/extended_contigs

while IFS=$'\t' read -r fa r1 r2; do
    file=$(basename $fa)
    id=${file%%.*}

    # First assemble each sample with a metagenomic assembler. Currently, we support MEGAHIT:
    bowtie2-build --threads 8 "${fa}" "${OUTDIR}/${id}"
    bowtie2 --threads 8 -x "${OUTDIR}/${id}" -1 "${r1}" -2 "${r2}" | samtools view -@ 2 -bS -h - > "${OUTDIR}/${id}_mapping.bam"

    # Next, sort the mappings by read name.
    samtools sort -n -@ 4 -o "${OUTDIR}/${id}_sorted_mapping.bam" "${OUTDIR}/${id}_mapping.bam"

    # Then run paired-end extension. 
    extension -t 8 -i "${fa}" -b "${OUTDIR}/${id}_sorted_mapping.bam" --pe-only -o ${OUTDIR}/extended_contigs -n "${id}"

    rm ${OUTDIR}/*.bt2
    rm ${OUTDIR}/*.bam

done < ${MANIFEST}
