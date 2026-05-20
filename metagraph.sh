#!/usr/bin/env bash

# Metagraph is scary, this script makes it less so...

set -euo pipefail

MANIFEST=""
OUTDIR=""
CPUS=""
MEM=""
BATCH_SIZE=""
MIN_K=31

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Options:
  -m, --manifest                            Path to manifest file
  -o, --outdir                              Path to output directory
  -c, --cpus                                No. CPUs
  -M, --memory                              Amount of memory to request (Gb) - script will use (memory - 2)
  -b, --batch_size                          Size of batches to split manifest into
  -k, --min_k                               Minimum k-mer size (default: 31)
  -h, --help                                Show this message
Examples:
  $(basename "$0") --manifest /path/to/manifest.txt --outdir /path/to/outdir --cpus 4 --memory 16 --batch_size 500
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--manifest)
            MANIFEST="$2"
            shift 2
            ;;
        -o|--outdir)
            OUTDIR="$2"
            shift 2
            ;;
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -M|--memory)
            MEM=$(( $2 - 2 ))
            shift 2
            ;;
        -b|--batch_size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        -k|--min_k)
            MIN_K="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: Unknown argument -> $1"
            exit 1
            ;;
        *)
            echo "Error: This script does not accept positional arguments"
            exit 1
            ;;
    esac
done

# STAGE 1

RES="-p ${CPUS} --disk-swap /tmp --mem-cap-gb ${MEM}"

echo "Commencing STAGE 1: Batch input"

mkdir -p "${OUTDIR}"
split -l "${BATCH_SIZE}" -d --additional-suffix=".txt" "${MANIFEST}" "${OUTDIR}/batch"

for batch in "${OUTDIR}"/batch*.txt; do
    batch_name=$(basename "${batch}" .txt)
    mkdir -p "${OUTDIR}/${batch_name}"

    while IFS=$'\t' read -r file; do
        base=$(basename "${file}")
        id="${base%%_genomic*}"

        metagraph build -p "${CPUS}" \
            -k "${MIN_K}" \
            --mode basic \
            -o "${OUTDIR}/${batch_name}/${id}" "${file}"

        metagraph transform -p "${CPUS}" \
            --to-fasta \
            --primary-kmers \
            -o "${OUTDIR}/${batch_name}/${id}.contigs" \
            "${OUTDIR}/${batch_name}/${id}.dbg"

    done < "${batch}"
    echo "Finished ${batch}"
done

# STAGE 2

echo "Commencing STAGE 2: Build graph from contigs"

find "${OUTDIR}" -name "*.contigs.fasta.gz" | metagraph build ${RES} \
    -k "${MIN_K}" \
    --mode canonical \
    -o "${OUTDIR}/joint"

metagraph transform ${RES} \
    --to-fasta \
    --primary-kmers \
    -o "${OUTDIR}/contigs" \
    "${OUTDIR}/joint.dbg"

metagraph build ${RES} \
    -k "${MIN_K}" \
    --mode primary \
    -o "${OUTDIR}/joint_graph" \
    "${OUTDIR}/contigs.fasta.gz"

rm ${OUTDIR}/batch*/*.dbg
rm ${OUTDIR}/batch*/*.fasta.gz
rm ${OUTDIR}/joint.dbg
rm ${OUTDIR}/contigs.fasta.gz

# STAGE 3

echo "Commencing STAGE 3: Annotate graph"

for batch in "${OUTDIR}"/batch*.txt; do
    batch_name=$(basename "${batch}" .txt)
    mkdir -p "${OUTDIR}/${batch_name}"

    metagraph annotate -i ${OUTDIR}/joint_graph.dbg \
        --anno-filename \
        -p ${CPUS} \
        -o "${OUTDIR}/${batch_name}/${batch_name}" \
        < ${batch}

    echo "Finished ${batch}"
done

# STAGE 4

echo "Commencing STAGE 4: Transform annotations"

mkdir -p ${OUTDIR}/rd_columns

transform_stage() {
    local stage="$1"

    find ${OUTDIR} -name "*.column.annodbg" | metagraph transform_anno ${RES} \
        --anno-type row_diff \
        --row-diff-stage ${stage} \
        -i ${OUTDIR}/joint_graph.dbg \
        -o ${OUTDIR}/rd_columns/out
}

transform_stage 0
echo "Completed RowDiff Stage 0"

transform_stage 1
echo "Completed RowDiff Stage 1"

transform_stage 2
echo "Completed RowDiff Stage 2"

echo "Commencing STAGE 5: Transform columns and relax BRWT"

find . -name "*.row_diff.annodbg" | metagraph transform_anno ${RES} \
    --anno-type row_diff_brwt \
    -i ${OUTDIR}/joint_graph.dbg \
    -o ${OUTDIR}/rd_brwt

metagraph relax_brwt ${RES} \
    --relax-arity 32 \
    -o ${OUTDIR}/relaxed \
    ${OUTDIR}/rd_brwt.row_diff_brwt.annodbg

rm -r ${OUTDIR}/batch*
rm -r ${OUTDIR}/rd_columns
rm ${OUTDIR}/joint_graph.dbg.*
rm ${OUTDIR}/rd_brwt.*

echo "All stages complete!"
echo "Final graph saved to ${OUTDIR}/joint_graph.dbg"
echo "Final annotations saved to ${OUTDIR}/relaxed.row_diff_brwt.annodbg"
