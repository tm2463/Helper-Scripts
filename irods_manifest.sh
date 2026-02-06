#!/bin/bash

manifest="$1"

> results.txt

tail -n +2 "$manifest" | while IFS="," read -r study run lane plex type; do

    study=$(echo "$study" | xargs)
    run=$(echo "$run" | xargs)
    lane=$(echo "$lane" | xargs)
    plex=$(echo "$plex" | xargs)
    type=$(echo "$type" | xargs)

    echo "DEBUG: study=$study run=$run lane=$lane plex=$plex type=$type"

    echo "Search: ${study} ${run} ${lane} ${plex} ${type}" >> results.txt
    command=$(imeta qu -z seq -d id_run = $run and lane = $lane and tag_index = $plex and type = $type)
    echo $command | tr '\n' ' ' >> results.txt
    echo "" >> results.txt

done
