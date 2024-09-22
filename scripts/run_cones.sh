#!/bin/bash

# Check if the correct number of arguments is passed
if [ "$#" -ne 1 ]; then
    echo "Usage: ./run_cones.sh <benchmark_name>"
    exit 1
fi

# Assign the benchmark name and dynamically construct the paths
benchmark_name=$1
design_file="../benchmarks/${benchmark_name}.v"
top_module=$benchmark_name

# Check if the Verilog file exists
if [ ! -f "$design_file" ]; then
    echo "Error: Verilog file '$design_file' not found."
    exit 1
fi

# Create directories for storing logic cones and optimized files
mkdir -p ../logic_cones
mkdir -p ../optimized_cones

# Create a temporary Yosys script to process the specific design
cat <<EOT > temp_yosys_script.ys
# Read the Verilog file
read_verilog $design_file

# Set the top module
hierarchy -check -top $top_module

# Process the design and flatten the hierarchy
proc; flatten;

# Write the whole design to JSON for debugging
write_json ../design.json
EOT

# Step 1: Run Yosys to generate the design.json
yosys -s temp_yosys_script.ys

# Check if Yosys successfully generated the design.json
if [ ! -f "../design.json" ]; then
    echo "Error: Yosys failed to generate design.json."
    exit 1
fi

# Step 2: Run Python script to extract output names
output_signals=$(python3 extract_outputs.py)

# Step 3: Loop through each output and process it
for output in $output_signals; do
  # Create a temporary Yosys script to isolate each output cone
  cat <<EOT > temp_extract_$output.ys
  # Read the Verilog file
  read_verilog $design_file

  # Set the top module
  hierarchy -check -top $top_module

  # Process the design, flatten it, and ensure standard logic gates are used
  proc; flatten;
  opt_clean -purge;  # Clean up unused logic
  techmap;  # Map internal Yosys cells to standard gates
  opt -full;

  # Select the output wire and write the logic cone to the BLIF file
  select -assert-output $output
  write_blif ../logic_cones/logic_cone_$output.blif
EOT

  # Extract logic cone for the output using Yosys
  yosys -s temp_extract_$output.ys

  # Check if the BLIF file was created
  if [ ! -f "../logic_cones/logic_cone_$output.blif" ]; then
    echo "Error: Yosys failed to generate logic cone for $output."
    exit 1
  fi

  # Optimize the logic cone using ABC
  abc -c "read_blif ../logic_cones/logic_cone_$output.blif; strash; collapse; write_blif ../optimized_cones/optimized_logic_cone_$output.blif"

  # Check if ABC successfully generated the optimized BLIF file
  if [ ! -f "../optimized_cones/optimized_logic_cone_$output.blif" ]; then
    echo "Error: ABC failed to optimize logic cone for $output."
    exit 1
  fi

  # Run the Python TLG conversion script for each optimized BLIF file
  python3 ../tlg_conversion.py "../optimized_cones/optimized_logic_cone_$output.blif"
done

# Clean up the temporary Yosys script
rm temp_yosys_script.ys

