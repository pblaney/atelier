#!/bin/bash
#SBATCH --partition=cpu_medium
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=12G
#SBATCH --time=2-00:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-bamMerger-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script merges multiple BAM files into a single BAM file"
    echo "and validates the merged BAM integrity"
    echo
    echo "Features:"
    echo "  - Merge multiple BAM files using Sambamba"
    echo "  - Automatic BAM indexing"
    echo "  - Validates BAM integrity after merging"
    echo "  - Multi-threaded processing"
    echo "  - Supports single merge or batch operations"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] bamMerger.sh -i [inputDir] -o [outputBam] [options]'
    echo
    echo "Required Arguments:"
    echo "  -i [inputDir]   Directory containing BAM files to merge"
    echo "  -o [outputBam]  Output merged BAM file name (or path)"
    echo
    echo "Optional Arguments:"
    echo "  -n              Dry run - show what would be processed"
    echo "  -v              Verbose output"
    echo "  -h              Print this help message"
    echo
    echo "File Format:"
    echo "  - Input directory should contain .bam files"
    echo "  - All BAMs will be merged into a single output file"
    echo "  - Output file can include path: /path/to/output.merged.bam"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Basic merge to current directory"
    echo '  sbatch --job-name=bam-merge bamMerger.sh -i /path/to/bams/ -o merged.bam'
    echo
    echo "  # Merge to specific output directory"
    echo '  sbatch --job-name=bam-merge bamMerger.sh -i /path/to/bams/ -o /output/merged.bam'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=bam-preview bamMerger.sh -i /path/to/bams/ -o merged.bam -n'
    echo
    echo "  # Verbose mode"
    echo '  sbatch --job-name=bam-verbose bamMerger.sh -i /path/to/bams/ -o merged.bam -v'
    echo
    echo "Output:"
    echo "  - Merged BAM file at specified location"
    echo "  - BAM index file (.bai)"
    echo "  - Log file: mergedBams.log (created in current directory)"
    echo
}

#################### Utility Functions ####################

# Function to print formatted timestamps
timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

# Function to print section headers
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))
    echo
    printf '%*s' "$width" | tr ' ' '~'
    echo
    printf '~%*s%s%*s~\n' "$padding" "" "$title" "$((width - padding - ${#title} - 2))" ""
    printf '%*s' "$width" | tr ' ' '~'
    echo
    echo
}

# Function to format file size
format_size() {
    local size=$1
    
    # Handle empty or non-numeric input
    if [ -z "$size" ] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "unknown size"
        return
    fi
    
    if [ "$size" -ge 1099511627776 ]; then
        echo "$(echo "scale=2; $size/1099511627776" | bc) TB"
    elif [ "$size" -ge 1073741824 ]; then
        echo "$(echo "scale=2; $size/1073741824" | bc) GB"
    elif [ "$size" -ge 1048576 ]; then
        echo "$(echo "scale=2; $size/1048576" | bc) MB"
    elif [ "$size" -ge 1024 ]; then
        echo "$(echo "scale=2; $size/1024" | bc) KB"
    else
        echo "$size B"
    fi
}

# Function to format duration
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ "$hours" -gt 0 ]; then
        printf "%dh %dm %ds" "$hours" "$minutes" "$secs"
    elif [ "$minutes" -gt 0 ]; then
        printf "%dm %ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# Function to convert relative path to absolute path
get_absolute_path() {
    local input_path="$1"
    local abs_path=""
    
    # If already absolute, just clean it up
    if [[ "$input_path" == /* ]]; then
        abs_path="$input_path"
    else
        # Relative path - prepend current directory
        abs_path="$(pwd)/${input_path}"
    fi
    
    # If path exists, try to resolve it properly
    if [ -e "$abs_path" ]; then
        if command -v realpath &> /dev/null; then
            abs_path=$(realpath "$abs_path")
        elif command -v readlink &> /dev/null && readlink -f "$abs_path" &> /dev/null; then
            abs_path=$(readlink -f "$abs_path")
        fi
    fi
    
    # Clean up double slashes
    abs_path=$(echo "$abs_path" | sed 's|//\+|/|g')
    
    echo "$abs_path"
}

# Function to validate BAM file (quick check only)
validate_bam() {
    local bam_file="$1"
    
    if [ ! -f "$bam_file" ]; then
        echo "[$(timestamp)] ERROR: BAM file not found: $bam_file"
        return 1
    fi
    
    echo "[$(timestamp)] Validating merged BAM: $(basename "$bam_file")"
    
    # Quick check for file integrity
    if ! samtools quickcheck "$bam_file" 2>/dev/null; then
        echo "[$(timestamp)] ✗ Quick check FAILED - BAM file is corrupted"
        return 1
    fi
    
    echo "[$(timestamp)] ✓ Quick check PASSED"
    return 0
}

# Function to get BAM file size only
get_bam_stats() {
    local bam_file="$1"
    
    local file_size
    file_size=$(stat --printf="%s" "$bam_file" 2>/dev/null || stat -f%z "$bam_file" 2>/dev/null || echo "0")
    
    echo "$file_size"
}

# Function to merge BAM files
merge_bams() {
    local input_dir="$1"
    local output_bam="$2"
    local threads="$3"
    local dry_run="$4"
    local verbose="$5"
    
    # Find all BAM files in input directory
    local bam_count
    bam_count=$(find "$input_dir" -maxdepth 1 -name "*.bam" -type f | wc -l)
    
    if [ "$bam_count" -eq 0 ]; then
        echo "[$(timestamp)] ERROR: No BAM files found in input directory"
        return 1
    fi
    
    # Calculate total input size
    local total_input_size=0
    while IFS= read -r bam_file; do
        local_size=$(stat --printf="%s" "$bam_file" 2>/dev/null || stat -f%z "$bam_file" 2>/dev/null || echo "0")
        total_input_size=$((total_input_size + local_size))
    done < <(find "$input_dir" -maxdepth 1 -name "*.bam" -type f)
    
    local formatted_input_size
    formatted_input_size=$(format_size "$total_input_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would merge $bam_count BAM files"
        echo "[$(timestamp)] [DRY RUN] Total input size: $formatted_input_size"
        echo "[$(timestamp)] [DRY RUN] Output: $(basename "$output_bam")"
        echo "[$(timestamp)] [DRY RUN] Threads: $threads"
        return 0
    fi
    
    echo "[$(timestamp)] Merging $bam_count BAM files"
    echo "[$(timestamp)]   Total input size: $formatted_input_size"
    echo "[$(timestamp)]   Output: $(basename "$output_bam")"
    echo "[$(timestamp)]   Threads: $threads"
    
    local start_time
    start_time=$(date +%s)
    
    # Build sambamba merge command
    local sambamba_cmd="sambamba-0.6.8 merge"
    sambamba_cmd="$sambamba_cmd -t $threads"
    sambamba_cmd="$sambamba_cmd -p"
    sambamba_cmd="$sambamba_cmd \"$output_bam\""
    
    # Add all BAM files to command
    while IFS= read -r bam_file; do
        sambamba_cmd="$sambamba_cmd \"$bam_file\""
    done < <(find "$input_dir" -maxdepth 1 -name "*.bam" -type f | sort)
    
    if [ "$verbose" = "true" ]; then
        echo "[$(timestamp)] Command: $sambamba_cmd"
    fi
    
    # Execute merge
    if ! eval "$sambamba_cmd"; then
        echo "[$(timestamp)] FAILED: BAM merge failed"
        return 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    echo "[$(timestamp)] ✓ Merge completed in $formatted_duration"
    
    # Index the output BAM
    echo "[$(timestamp)] Indexing output BAM..."
    if ! samtools index "$output_bam" 2>/dev/null; then
        echo "[$(timestamp)] WARNING: Failed to create BAM index"
        return 1
    fi
    echo "[$(timestamp)] ✓ Index created"
    
    # Get output BAM size
    local output_size
    output_size=$(get_bam_stats "$output_bam")
    local formatted_output_size
    formatted_output_size=$(format_size "$output_size")
    
    echo "[$(timestamp)] Output size: $formatted_output_size"
    echo "[$(timestamp)] Compression ratio: $(echo "scale=2; $output_size * 100 / $total_input_size" | bc)%"
    
    # Automatic validation after merge
    echo "[$(timestamp)] Running automatic validation..."
    if validate_bam "$output_bam"; then
        echo "[$(timestamp)] ✓✓✓ BAM validation PASSED - File is ready to use"
        return 0
    else
        echo "[$(timestamp)] ✗✗✗ BAM validation FAILED - File may be corrupted"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
INPUT_DIR=""
OUTPUT_BAM=""
DRY_RUN="false"
VERBOSE="false"

# Hard-set threads from SLURM header
THREADS=4

# Parse command line options
while getopts ":hi:o:nv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        i) # Input directory
            INPUT_DIR="$OPTARG"
            ;;
        o) # Output BAM
            OUTPUT_BAM="$OPTARG"
            ;;
        n) # Dry run
            DRY_RUN="true"
            ;;
        v) # Verbose
            VERBOSE="true"
            ;;
        \?) # Invalid option
            echo "Invalid option: -$OPTARG"
            Help
            exit 1
            ;;
        :) # Missing argument
            echo "Option -$OPTARG requires an argument"
            Help
            exit 1
            ;;
    esac
done

############################################################
# Debugging settings
set -euo pipefail

print_header "BAM Merger"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"
echo

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if input directory is provided
if [ -z "$INPUT_DIR" ]; then
    echo "[$(timestamp)] ERROR: Input directory (-i) is required"
    Help
    exit 1
fi

# Convert input directory to absolute path
INPUT_DIR=$(get_absolute_path "$INPUT_DIR")

if [ ! -d "$INPUT_DIR" ]; then
    echo "[$(timestamp)] ERROR: Input directory not found: $INPUT_DIR"
    exit 1
fi

echo "[$(timestamp)] Input directory: $INPUT_DIR"

# Check if output BAM is provided
if [ -z "$OUTPUT_BAM" ]; then
    echo "[$(timestamp)] ERROR: Output BAM file (-o) is required"
    Help
    exit 1
fi

# Convert output BAM path to absolute if relative
if [[ "$OUTPUT_BAM" != /* ]]; then
    OUTPUT_BAM="$(pwd)/${OUTPUT_BAM}"
fi

# Ensure output directory exists
output_dir=$(dirname "$OUTPUT_BAM")
if [ ! -d "$output_dir" ]; then
    echo "[$(timestamp)] ERROR: Output directory does not exist: $output_dir"
    exit 1
fi

echo "[$(timestamp)] Output BAM: $OUTPUT_BAM"
echo "[$(timestamp)] Threads: $THREADS (from SLURM allocation)"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Verbose output: $VERBOSE"

#################### Load Required Tools ####################

print_header "Environment Setup"

# Try to load required modules
if command -v module &> /dev/null; then
    echo "[$(timestamp)] Loading required modules..."
    
    # Load Sambamba
    module load sambamba/0.6.8 2>/dev/null || echo "[$(timestamp)] WARNING: Could not load Sambamba module, checking system PATH"
    
    # Load SAMtools
    module load samtools 2>/dev/null || module load SAMtools 2>/dev/null || echo "[$(timestamp)] WARNING: Could not load SAMtools module, checking system PATH"
    
    module list -t 2>&1 | grep -E "sambamba|samtools" || true
fi

# Verify Sambamba is available
if ! command -v sambamba-0.6.8 &> /dev/null; then
    echo "[$(timestamp)] ERROR: Sambamba is not installed or not in PATH"
    exit 1
fi

# Verify SAMtools is available
if ! command -v samtools &> /dev/null; then
    echo "[$(timestamp)] ERROR: SAMtools is not installed or not in PATH"
    exit 1
fi

echo "[$(timestamp)] Sambamba version: $(sambamba-0.6.8 --version 2>&1 | head -1)"
echo "[$(timestamp)] SAMtools version: $(samtools --version | head -1)"
echo

#################### Count BAM Files ####################

print_header "Building BAM File List"

echo "[$(timestamp)] Searching for BAM files in: $INPUT_DIR"

# Count BAM files
BAM_COUNT=$(find "$INPUT_DIR" -maxdepth 1 -name "*.bam" -type f | wc -l)

if [ "$BAM_COUNT" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No BAM files found in input directory"
    exit 1
fi

echo "[$(timestamp)] Total BAM files to merge: $BAM_COUNT"
echo

# Preview BAM files based on count
if [ "$BAM_COUNT" -eq 1 ]; then
    echo "[$(timestamp)] BAM file to merge:"
    find "$INPUT_DIR" -maxdepth 1 -name "*.bam" -type f | sort | while IFS= read -r bam; do
        local_size=$(format_size "$(stat --printf="%s" "$bam" 2>/dev/null || stat -f%z "$bam" 2>/dev/null || echo "0")")
        echo "  - $(basename "$bam") ($local_size)"
    done
elif [ "$BAM_COUNT" -le 5 ]; then
    echo "[$(timestamp)] All $BAM_COUNT BAM files to merge:"
    find "$INPUT_DIR" -maxdepth 1 -name "*.bam" -type f | sort | while IFS= read -r bam; do
        local_size=$(format_size "$(stat --printf="%s" "$bam" 2>/dev/null || stat -f%z "$bam" 2>/dev/null || echo "0")")
        echo "  - $(basename "$bam") ($local_size)"
    done
else
    echo "[$(timestamp)] First 5 of $BAM_COUNT BAM files to merge:"
    find "$INPUT_DIR" -maxdepth 1 -name "*.bam" -type f | sort | head -5 | while IFS= read -r bam; do
        local_size=$(format_size "$(stat --printf="%s" "$bam" 2>/dev/null || stat -f%z "$bam" 2>/dev/null || echo "0")")
        echo "  - $(basename "$bam") ($local_size)"
    done
    echo "  ... and $((BAM_COUNT - 5)) more files"
fi

#################### Merge BAM Files ####################

print_header "Merging BAM Files"

echo "[$(timestamp)] Starting BAM merge process..."
echo

# Record start time
JOB_START_TIME=$(date +%s)

# Perform merge
if merge_bams "$INPUT_DIR" "$OUTPUT_BAM" "$THREADS" "$DRY_RUN" "$VERBOSE"; then
    MERGE_SUCCESS=true
else
    MERGE_SUCCESS=false
fi

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Summary ####################

print_header "Merge Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total BAM files merged: $BAM_COUNT"
echo "  Output BAM:            $(basename "$OUTPUT_BAM")"
echo "  Output location:       $(dirname "$OUTPUT_BAM")"
echo
echo "  Threads used:          $THREADS"
echo "  Dry run:               $DRY_RUN"
echo "  Total time:            $(format_duration $JOB_DURATION)"
echo

if [ "$MERGE_SUCCESS" = true ] && [ "$DRY_RUN" = "false" ]; then
    # Get final output size
    local final_size
    final_size=$(get_bam_stats "$OUTPUT_BAM")
    local formatted_final_size
    formatted_final_size=$(format_size "$final_size")
    
    echo "  Final BAM size:        $formatted_final_size"
    echo
    
    echo "------------------------------------------------------------"
    echo "  SUCCESS: $BAM_COUNT files merged successfully!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
elif [ "$DRY_RUN" = "true" ]; then
    echo "------------------------------------------------------------"
    echo "  DRY RUN COMPLETE: Ready to merge $BAM_COUNT files"
    echo
    echo "[$(timestamp)] Dry run completed - no files were actually merged"
    exit 0
else
    echo "------------------------------------------------------------"
    echo "  MERGE FAILED: Check output above for errors"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

# Create log file
LOG_FILE="mergedBams.log"
{
    echo "BAM Merge Summary"
    echo "================"
    echo "Timestamp: $(timestamp)"
    echo "Input directory: $INPUT_DIR"
    echo "Output BAM: $OUTPUT_BAM"
    echo "BAM files merged: $BAM_COUNT"
    echo "Threads: $THREADS"
    echo "Dry run: $DRY_RUN"
    echo "Total time: $(format_duration $JOB_DURATION)"
    echo ""
    echo "Status: $([ "$MERGE_SUCCESS" = true ] && echo "SUCCESS" || echo "FAILED")"
} > "$LOG_FILE"

echo "[$(timestamp)] Log file created: $LOG_FILE"

print_header "End of Job"