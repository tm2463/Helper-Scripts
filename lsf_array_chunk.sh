#!/usr/bin/env bash

MAIN_LIST=""
OUTDIR=""
BATCH_SIZE=
CONCURRENCY=
JOB_TITLE=""
SCRIPT_PATH=""
MEMORY=
CPUS=
QUEUE=""
LOG_FILE=""

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -m, --main_list                           Path to main list of files
  -o, --outdir                              Path to output directory
  -b, --batch_size                          Size of batches to be submitted
  -c, --concurrency                         How many batches to process at once
  -j, --job_title                           Name of job to be submitted
  -s, --script                              Path to executor script
  -M, --memory                              Amount of memory to request (Gb)
  -C, --cpus                                No. CPUs
  -q, --queue                               Queue to which jobs are submitted
  -l, --log_file                            Prefix to name standard output and error files
  -h, --help                                Show this message

Examples:
  $(basename "$0") --main_list /path/to/main_list.txt
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in 
        -m|--main_list)
            MAIN_LIST="$2"
            shift 2
            ;;
        -o|--outdir)
            OUTDIR="$2"
            shift 2
            ;;
        -b|--batch_size)
            BATCH_SIZE="$2"
            shift 2
            ;;
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        -j|--job_title)
            JOB_TITLE="$2"
            shift 2
            ;;
        -s|--executor_script)
            SCRIPT_PATH="$2"
            shift 2
            ;;
        -M|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -C|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -q|--queue)
            QUEUE="$2"
            shift 2
            ;;
        -l|--log_file)
            LOG="$2"
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

N_JOBS=$(wc -l < $MAIN_LIST)
N_CHUNKS=$(( ($N_JOBS + $BATCH_SIZE - 1) / $BATCH_SIZE ))
BATCH_LIST=${OUTDIR}/batch_list.txt

mkdir -p "$OUTDIR"

> "$BATCH_LIST"
for i in $(seq 1 $N_CHUNKS); do
    START_CHUNK=$(( ((${i} - 1 ) * ${BATCH_SIZE}) + 1 ))
    END_CHUNK=$(( i * $BATCH_SIZE ))
    if (( END_CHUNK > N_JOBS )); then
        END_CHUNK=$N_JOBS
    fi
    BATCH_FILE=${OUTDIR}/batch_${i}.txt
    sed -n "${START_CHUNK},${END_CHUNK}p" $MAIN_LIST > $BATCH_FILE
    echo "$BATCH_FILE" >> $BATCH_LIST
done

export CPUS
MEM=$(( ${MEMORY} * 1024 )) #convert to Mb
bsub -J ${JOB_TITLE}[1-${N_CHUNKS}]%$CONCURRENCY \
    -R "select[mem>${MEM}] rusage[mem=${MEM}] span[hosts=1]" \
    -M ${MEM} \
    -n ${CPUS} \
	  -q ${QUEUE} \
    -e ${LOG}.%J.%I.log \
    -o ${LOG}.%J.%I.log \
	  ${SCRIPT_PATH} # insert arguments
