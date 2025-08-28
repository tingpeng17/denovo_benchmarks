#!/bin/bash
dset_dir="$1"
algorithm_name="$2"
split_n="$3"
spectra_dir="$dset_dir/mgf"
output_root_dir="./outputs"
time_log_root_dir="./times"
overlay_size=2048

echo "Running benchmark with $algorithm_name on dataset $dset_name."

# get dataset name
dset_name=$(basename "$dset_dir")
# List input files
echo "Processing dataset: $dset_name ($dset_dir)"
ls "$spectra_dir"/*.mgf

# Store (sorted) input files in a bash array
mapfile -t mgf_files < <(find "$spectra_dir" -maxdepth 1 -type f -name '*.mgf' | sort)
total_files=${#mgf_files[@]}

part_size=$(( (total_files + split_n - 1) / split_n ))
# iterate through parts
for part_idx in $(seq 0 $((split_n-1))); do

    start=$(( part_idx * part_size ))
    end=$(( start + part_size - 1 ))
    (( start >= total_files )) && break        # nothing left
		
	# For each part, create output_dir and time_log_dir
	part_output_dir="$output_root_dir/${dset_name}_part_${part_idx}"
    part_time_log_dir="$time_log_root_dir/${dset_name}_part_${part_idx}"
    # Create the output directory if it doesn't exist
    mkdir -p "$part_output_dir" "$part_time_log_dir"
    
    # get algorithm files path(?), names for output files for this algorithm_name(!)
    # TODO: need also some check that $algorithm_name argument is a valid algorithm name 
    # = name of one of the tools in $algorithm_dir
    # smth like here
    # if [ -d "$algorithm_dir" ] && [ $(basename "$algorithm_dir") != "base" ]; then
    #     algorithm_name=$(basename "$algorithm_dir")
    
    time_log_file="$part_time_log_dir/${algorithm_name}_time.log"
    output_file="$part_output_dir/${algorithm_name}_output.csv"
    echo "Output file: $output_file"
    
    # Check if the output file does not exist
    if [ ! -e "$output_file" ]; then
        echo "Running algorithm ${algorithm_name} for ${dset_name} part ${part}:"
        
        # create a "subset dataset"
			  # - create a temporary directory that will hold just this slice
		    tmp_part_dir=$(mktemp -d)
		    echo "Create tmp dir ${tmp_part_dir}"
		    # - populate that directory with symlinks to the real files
		    for i in $(seq "$start" "$end"); do
		        (( i >= total_files )) && break
		        ln -s "${mgf_files[$i]}" "$tmp_part_dir/"
		    done

        # Remove an existing container overlay, if any
        rm -rf "algorithms/${algorithm_name}/overlay_${dset_name}.img"
        # Create writable overlay for the container
        apptainer overlay create --fakeroot --size $overlay_size --sparse "algorithms/${algorithm_name}/overlay_${dset_name}.img"

        # Calculate predictions
        echo "RUN ALGORITHM $algorithm_name"
        { time ( apptainer exec --fakeroot --nv \
        --overlay "algorithms/${algorithm_name}/overlay_${dset_name}.img" \
        -B "${tmp_part_dir}":"/algo/${dset_name}" \
        --env-file .env \
        "algorithms/${algorithm_name}/container.sif" \
        bash -c "cd /algo && ./make_predictions.sh ${dset_name}" 2>&1 ); } 2> "$time_log_file"
                
        # Collect predictions in output_dir
        echo "EXPORT PREDICTIONS"
        apptainer exec --fakeroot \
            --overlay "algorithms/${algorithm_name}/overlay_${dset_name}.img" \
            -B "${part_output_dir}":/algo/outputs \
            --env-file .env \
            "algorithms/${algorithm_name}/container.sif" \
            bash -c "cp /algo/outputs.csv /algo/outputs/${algorithm_name}_output.csv"
        
        # Clean up the temporary directory
        rm -rf "$tmp_part_dir"

    else
        echo "Skipping ${dset_name} part ${part}. Output file already exists."
        # Remove an existing container overlay, if any
        # FIXME: mb put this part outside if-else statement? 
        # Now when each dataset has separate container overlays,
        # old dataset overlays must be removed if output file already exists.
        rm -rf "algorithms/${algorithm_name}/overlay_${dset_name}.img"
    fi

done


echo "All parts complete - merging outputs."

output_dir="$output_root_dir/$dset_name"
time_log_dir="$time_log_root_dir/$dset_name"
# Create the output directory if it doesn't exist
mkdir -p "$output_dir" "$time_log_dir"

merged_csv="$output_dir/${algorithm_name}_output.csv"
merged_time="$time_log_dir/${algorithm_name}_time.log"

# Merge output CSVs (keep header from part 0, then append the rest)
first_part="$output_root_dir/${dset_name}_part_0/${algorithm_name}_output.csv"
head -n 1 "$first_part" > "$merged_csv"
for part_idx in $(seq 0 $((split_n-1))); do
    tail -n +2 "$output_root_dir/${dset_name}_part_${part_idx}/${algorithm_name}_output.csv" >> "$merged_csv"
done

# Sum logged inference times
total_sec=0
for part_idx in $(seq 0 $((split_n-1))); do
    real_line=$(grep '^real' "$time_log_root_dir/${dset_name}_part_${part_idx}/${algorithm_name}_time.log")
    if [[ $real_line =~ ([0-9]+)m([0-9]+\.[0-9]+)s ]]; then
        mins=${BASH_REMATCH[1]} ; secs=${BASH_REMATCH[2]}
        part_sec=$(awk "BEGIN {print $mins*60+$secs}")
    else
        part_sec=$(echo "$real_line" | sed -E 's/real +([0-9.]+)s/\1/')
    fi
    total_sec=$(awk "BEGIN {print $total_sec + $part_sec}")
done
printf 'real %.3fs\n' "$total_sec" > "$merged_time"

# clean per-part artefacts
echo "Removing per-part folders and overlays"
for part_idx in $(seq 0 $((split_n-1))); do
    rm -rf "$output_root_dir/${dset_name}_part_${part_idx}" \
           "$time_log_root_dir/${dset_name}_part_${part_idx}"
    rm -f  "algorithms/${algorithm_name}/overlay_${dset_name}_part_${part_idx}.img"
done

# Evaluate predictions
# TODO: add results_dir explicit definition
echo "EVALUATE PREDICTIONS"
apptainer exec --fakeroot --env-file .env "evaluation.sif" \
    bash -c "python evaluate.py ${output_dir}/ ${dset_dir}"