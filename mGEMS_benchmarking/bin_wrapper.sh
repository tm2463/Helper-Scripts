#!/usr/bin/bash

SCRIPT="$1"
OUTDIR="$2"
CLOSE_MANIFEST="$3"
DISTANT_MANIFEST="$4"

while IFS= read -r path; do
    set=$(echo "$path" | rev | cut -d'/' -f2 | rev)
    "${SCRIPT}" "${path}" "CLOSE" "${set}" "${OUTDIR}"
done < "$CLOSE_MANIFEST"

while IFS= read -r path; do
    set=$(echo "$path" | rev | cut -d'/' -f2 | rev)
    "${SCRIPT}" "${path}" "DISTANT" "${set}" "${OUTDIR}"
done < "$DISTANT_MANIFEST"
