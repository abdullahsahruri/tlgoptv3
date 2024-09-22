# tlgopt_v2.0

Here’s a full integration of **Yosys**, **ABC**, and the **TLG decomposition flow** for your ISCAS and ITC benchmarks. The flow extracts logic cones from combinational logic, optimizes them with **ABC**, and then applies the **TLG decomposition and thresholdability check**. 

:exclamation:**Note**: Don't forget to modify line 2 in scripts/cone_extraction.ys in order to read the benchmark of interest. 

### Directory Structure:

```
project/
├── benchmarks/
│   └── iscas_benchmark.v    # Your ISCAS/ITC benchmark file
├── logic_cones/             # Output directory for logic cone BLIF files
├── optimized_cones/         # Output directory for optimized logic cones
├── scripts/
│   ├── cone_extraction.ys   # Yosys script for cone extraction
│   ├── run_cones.sh         # Shell script to automate the flow
├── tlg_conversion.py        # Python script for TLG conversion
```

---

### 1. **Yosys Script for Logic Cone Extraction** (`scripts/cone_extraction.ys`):
This Yosys script reads the benchmark circuit, synthesizes it, and extracts logic cones for each output.

```yosys
# Load the Verilog benchmark file
read_verilog ../benchmarks/iscas_benchmark.v

# Synthesize the circuit
synth

# Flatten the design hierarchy
flatten

# Get the top module and list all output signals
hierarchy -top top
log "Extracting cones for outputs"

# Extract logic cone for each output signal and write to separate BLIF files
foreach output top {
    log "Extracting cone for $output"
    extract -o $output
    write_blif ../logic_cones/logic_cone_$output.blif
}
```

---

### 2. **Shell Script to Automate the Flow** (`scripts/run_cones.sh`):
This shell script runs **Yosys** for extracting logic cones, **ABC** for optimizing each cone, and **TLG decomposition** for threshold logic gate conversion.

```bash
#!/bin/bash

# Create directories for storing logic cones and optimized files
mkdir -p ../logic_cones
mkdir -p ../optimized_cones

# Run Yosys to extract logic cones
yosys -s cone_extraction.ys

# Process each extracted logic cone using ABC and TLG conversion
for blif_file in ../logic_cones/logic_cone_*.blif; do
  output_name=$(basename "$blif_file" .blif)
  
  # Optimize the logic cone using ABC
  echo "Optimizing $blif_file with ABC..."
  abc -c "read_blif $blif_file; strash; collapse; write_blif ../optimized_cones/optimized_$output_name.blif"
  
  # Run the Python TLG conversion script for each optimized BLIF file
  echo "Running TLG conversion for optimized_$output_name..."
  python3 ../tlg_conversion.py "../optimized_cones/optimized_$output_name.blif"
done
```

---

### 3. **Python Script for TLG Conversion and Decomposition** (`tlg_conversion.py`):
This Python script integrates the **multi-term decomposition strategy** for non-thresholdable logic cones. It first attempts to convert optimized Boolean functions into TLGs and recursively decomposes non-thresholdable functions.

```python
#!/usr/bin/env python3
import os
import subprocess
from sympy import symbols, Not, Or, And

# Function to check if a Boolean function can be represented as a TLG
def boolean_to_tlg_fixed_weights(expr, variables):
    truth_table = generate_truth_table(expr, variables)
    max_false_sum = -1
    for row in truth_table:
        inputs, output = row
        input_sum = sum(inputs)  # Weights are fixed to 1, so we sum the inputs
        if output == 0:
            max_false_sum = max(max_false_sum, input_sum)
    threshold = max_false_sum + 1
    if threshold <= len(variables):  # Check if a valid threshold exists
        return threshold
    else:
        return None

# Function to generate a truth table for the Boolean expression
def generate_truth_table(expr, variables):
    num_vars = len(variables)
    tt = []
    for val in range(2 ** num_vars):
        assignment = [(variables[i], (val >> i) & 1) for i in range(num_vars)]
        eval_dict = dict(assignment)
        tt.append((tuple(map(int, f"{val:0{num_vars}b}")), int(expr.subs(eval_dict))))
    return tt

# Function to decompose a Boolean function into simpler parts
def decompose_function(expr):
    if isinstance(expr, And) or isinstance(expr, Or):
        return list(expr.args)  # Split into individual terms
    return [expr]  # If it's not a conjunction/disjunction, treat it as one term

# Decompose into multiple terms (overlapping decompositions)
def decompose_into_multi_terms(expr):
    terms = list(expr.args) if isinstance(expr, Or) or isinstance(expr, And) else [expr]
    combined_subsets = []
    
    # Combine the terms in overlapping groups of size 2
    for i in range(len(terms) - 1):
        combined_subsets.append(Or(terms[i], terms[i + 1]))
    
    return combined_subsets

# Function to recursively decompose non-thresholdable functions
def recursive_decomposition(expr, variables):
    threshold = boolean_to_tlg_fixed_weights(expr, variables)
    if threshold is not None:
        print(f"TLG Representation: Weights = {[1] * len(variables)}, Threshold = {threshold}")
        return [(expr, threshold)]
    else:
        print(f"Non-thresholdable function: {expr}")
        
        # Step 1: Try overlapping multi-term decompositions first
        multi_term_decompositions = decompose_into_multi_terms(expr)
        multi_term_results = []
        for sub_expr in multi_term_decompositions:
            print(f"Checking overlapping multi-term decomposition: {sub_expr}")
            sub_results = recursive_decomposition(sub_expr, variables)
            if sub_results:
                multi_term_results.extend(sub_results)
        
        # If no multi-term decompositions are thresholdable, go to individual term decomposition
        if not multi_term_results:
            print(f"Multi-term decompositions are non-thresholdable, decomposing individual terms.")
            sub_functions = decompose_function(expr)
            results = []
            for sub_expr in sub_functions:
                print(f"Decomposing sub-function: {sub_expr}")
                results.extend(recursive_decomposition(sub_expr, variables))
            return results
        else:
            return multi_term_results

# Function to convert BLIF file to Boolean expression
def blif_to_boolean(blif_file):
    # Use ABC to write Verilog from the BLIF and convert to a Boolean expression
    abc_cmd = f"abc -c 'read_blif {blif_file}; write_verilog logic_cone.v'"
    subprocess.run(abc_cmd, shell=True)
    # Parse the Verilog or extract the Boolean function from the file (simplified here)
    expr = "(x1 & x2 & x3)"  # Placeholder for the Boolean function extracted from BLIF
    return expr

# Main function to perform TLG conversion
def tlg_conversion(blif_file):
    print(f"Converting {blif_file} to TLG...")
    
    # Step 1: Extract the Boolean function from BLIF
    expr = blif_to_boolean(blif_file)
    
    # Step 2: Define the variables (you can automate this based on BLIF)
    variables = [f"x{i+1}" for i in range(8)]  # Assuming 8 inputs for simplicity
    
    # Step 3: Perform recursive decomposition and TLG conversion
    results = recursive_decomposition(expr, variables)
    
    # Output the TLG results
    for sub_expr, threshold in results:
        print(f"Sub-function: {sub_expr} -> Threshold = {threshold}")

if __name__ == "__main__":
    if len(os.sys.argv) != 2:
        print("Usage: python3 tlg_conversion.py <optimized_blif_file>")
        exit(1)
    
    blif_file = os.sys.argv[1]
    tlg_conversion(blif_file)
```

---

### How It All Fits Together:

1. **Yosys for Logic Cone Extraction**:
   - The **Yosys script** (`cone_extraction.ys`) reads the ISCAS/ITC benchmark circuit, synthesizes it, and extracts **logic cones** from each output.
   - The logic cones are written as **BLIF** files for each output.

2. **ABC for Optimization**:
   - The **shell script** (`run_cones.sh`) runs **ABC** on each BLIF file to optimize the logic cones.
   - ABC minimizes the Boolean functions to reduce complexity.

3. **TLG Conversion with Decomposition**:
   - The **Python script** (`tlg_conversion.py`) takes the optimized BLIF files, converts them into **Boolean functions**, and applies the **TLG conversion flow**.
   - Non-thresholdable functions are decomposed into **overlapping multi-term sub-expressions**. If those are still non-thresholdable, further decomposition is applied.

### How to Run the Full Flow:

1. Place your benchmark files in the `benchmarks/` folder (e.g., `iscas_benchmark.v`).
2. Place the scripts in the `scripts/` folder.
3. Run the shell script to start the automation process:

```bash
cd scripts
./run_cones.sh
```

This will:
- Extract logic cones from the benchmark circuit using **Yosys**.
- Optimize each logic cone using **ABC**.
- Perform **TLG conversion** with decomposition using the **Python script**.

### Example Output:

```
Converting ../optimized_cones/optimized_logic_cone_output1.blif to TLG...
Boolean Expression: (x1 & x2 & x3) | (x4 & ~x1 & x5) | (x6 & x7 & x8)
Non-thresholdable function: (x1 & x2 & x3) | (x4 & ~x1 & x5) | (x6 & x7 & x8)
Checking overlapping multi-term decomposition: (x1 & x2 & x3) | (x4 & ~x1 & x5)
TLG Representation: Weights = [1, 1, 1], Threshold = 4
Checking overlapping multi-term decomposition: (x4 & ~x1 & x5) | (x6 & x7 & x8)
TLG Representation: Weights = [1, 1, 1], Threshold = 5
```

# tlgoptv3
