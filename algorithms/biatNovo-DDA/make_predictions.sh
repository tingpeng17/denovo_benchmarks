#!/bin/bash

rm -f outputs.tab
rm -rf /algo/input_data
rm -rf /algo/outputs

# Get dataset property tags
DSET_TAGS=$(python /algo/base/dataset_tags_parser.py --dataset "$@")
while IFS='=' read -r key value; do
    export "$key"="$value"
done <<< "$DSET_TAGS"

mkdir -p /algo/input_data
mkdir -p /algo/outputs
export DENOVO_INPUT_DIR=/algo/input_data
export DENOVO_OUTPUT_DIR=/algo/outputs
export DENOVO_OUTPUT_FILE=outputs.tab

# Iterate through files in the dataset
for input_file in "$@"/*.mgf; do

    # Clean input dir (previous input files)
    rm -rf /algo/input_data/*

    echo "Processing file: $input_file"

    # Convert input data to model format
    python input_mapper.py \
        --input_path "$input_file" \
        --output_path /algo/input_data/input_data.mgf
    python biatNovo-DDA/Biatnovo/data_format_convert.py \
        --data_convert \
        --denovo_file /algo/input_data/input_data.mgf \
        --folder_name ./input_data

    # Run de novo algorithm on the input data
    python biatNovo-DDA/v2/main.py  --search_denovo --train_dir /algo/

done

# Convert predictions to the general output format
python output_mapper.py --output_path=/algo/outputs/outputs.tab
