#!/bin/bash
#SBATCH --partition=cpu_medium
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8s
#SBATCH --mem-per-cpu=2G
#SBATCH --time=1-00:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-cramConverter-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script converts CRAM files to BAM format using hg38 as reference"
    echo "and validates the converted files"
    echo
    echo "Features:"
    echo "  - Convert CRAM files to BAM format"
    echo "  - Uses hg38 reference genome"
    echo "  - Automatic BAM indexing"
    echo "  - Validates BAM integrity after conversion"
    echo "  - Multi-threaded processing"
    echo "  - Batch processing support"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/cramConverter.sh -i [inputDir] [options]'
    echo
    echo "Required Arguments:"
    echo "  -i [inputDir]   Directory containing CRAM files to convert"
    echo
    echo "Optional Arguments:"
    echo "  -o [outputDir]  Output directory for converted BAM files"
    echo "                  (default: inputDir/convertedBams)"
    echo "  -r [reference]  Path to reference genome FASTA"
    echo "                  (default: /gpfs/data/morganlab/referenceFiles/hg38/Homo_sapiens_assembly38.fasta)"
    echo "  -n              Dry run - show what would be processed"
    echo "  -v              Verbose output"
    echo "  -h              Print this help message"
    echo
    echo "File Format:"
    echo "  - Input directory should contain .cram files"
    echo "  - Each CRAM file will be converted to BAM"
    echo "  - Output files follow naming: [sampleName].bam"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Basic conversion to default output directory"
    echo '  sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh -i /path/to/crams/'
    echo
    echo "  # Convert to custom output directory"
    echo '  sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh -i /path/to/crams/ -o /output/bams/'
    echo
    echo "  # Use custom reference genome"
    echo '  sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh -i /path/to/crams/ -r /path/to/reference.fasta'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=cram-preview ~/atelier/bin/cramConverter.sh -i /path/to/crams/ -n'
    echo
    echo "  # Verbose mode"
    echo '  sbatch --job-name=cram-verbose ~/atelier/bin/cramConverter.sh -i /path/to/crams/ -v'
    echo
    echo "Output:"
    echo "  - Converted BAM files in output directory"
    echo "  - BAM index files (.bai)"
    echo "  - Log file: convertedCrams.log (created in current directory)"
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

# Function to print progress bar
print_progress() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r[$(timestamp)] Progress: ["
    printf '%*s' "$filled" | tr ' ' '*'
    printf '%*s' "$empty" | tr ' ' ' '
    printf "] %d/%d (%d%%)" "$current" "$total" "$percentage"
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
    
    echo "[$(timestamp)] Validating converted BAM: $(basename "$bam_file")"
    
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

# Function to convert a single CRAM file
convert_cram() {
    local input_cram="$1"
    local output_dir="$2"
    local reference="$3"
    local threads="$4"
    local dry_run="$5"
    local verbose="$6"
    
    # Extract sample name from CRAM filename
    local sample_name
    sample_name=$(basename "$input_cram" .cram)
    
    local output_bam="${output_dir}/${sample_name}.bam"
    
    # Get input CRAM size
    local input_size
    input_size=$(stat --printf="%s" "$input_cram" 2>/dev/null || stat -f%z "$input_cram" 2>/dev/null || echo "0")
    local formatted_input_size
    formatted_input_size=$(format_size "$input_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would convert: $(basename "$input_cram") ($formatted_input_size)"
        echo "[$(timestamp)] [DRY RUN] Output: $(basename "$output_bam")"
        echo "[$(timestamp)] [DRY RUN] Threads: $threads"
        return 0
    fi
    
    echo "[$(timestamp)] Converting: $(basename "$input_cram") ($formatted_input_size)"
    echo "[$(timestamp)]         -> $(basename "$output_bam")"
    echo "[$(timestamp)] Reference: $(basename "$reference")"
    
    local start_time
    start_time=$(date +%s)
    
    # Build samtools view command
    local samtools_cmd="samtools view"
    samtools_cmd="$samtools_cmd -b"
    samtools_cmd="$samtools_cmd --threads $threads"
    samtools_cmd="$samtools_cmd --reference \"$reference\""
    samtools_cmd="$samtools_cmd \"$input_cram\""
    samtools_cmd="$samtools_cmd > \"$output_bam\""
    
    if [ "$verbose" = "true" ]; then
        echo "[$(timestamp)] Command: $samtools_cmd"
    fi
    
    # Execute conversion
    if ! eval "$samtools_cmd"; then
        echo "[$(timestamp)] FAILED: CRAM to BAM conversion failed"
        return 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    echo "[$(timestamp)] ✓ Conversion completed in $formatted_duration"
    
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
    
    # Automatic validation after conversion
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
OUTPUT_DIR=""
REFERENCE="/gpfs/data/morganlab/referenceFiles/hg38/Homo_sapiens_assembly38.fasta"
DRY_RUN="false"
VERBOSE="false"

# Hard-set threads from SLURM header
THREADS=8

# Parse command line options
while getopts ":hi:o:r:nv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        i) # Input directory
            INPUT_DIR="$OPTARG"
            ;;
        o) # Output directory
            OUTPUT_DIR="$OPTARG"
            ;;
        r) # Reference genome
            REFERENCE="$OPTARG"
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

print_header "CRAM to BAM Converter"

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

# Set up output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${INPUT_DIR}/convertedBams"
    echo "[$(timestamp)] Output directory not specified, using: $OUTPUT_DIR"
else
    OUTPUT_DIR=$(get_absolute_path "$OUTPUT_DIR")
fi

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "[$(timestamp)] Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

echo "[$(timestamp)] Output directory: $OUTPUT_DIR"

# Validate reference genome
if [ ! -f "$REFERENCE" ]; then
    echo "[$(timestamp)] ERROR: Reference genome not found: $REFERENCE"
    exit 1
fi

echo "[$(timestamp)] Reference genome: $REFERENCE"
echo "[$(timestamp)] Threads: $THREADS (from SLURM allocation)"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Verbose output: $VERBOSE"

#################### Load SAMtools ####################

print_header "Environment Setup"

# Try to load SAMtools module
if command -v module &> /dev/null; then
    echo "[$(timestamp)] Loading SAMtools module..."
    module load samtools 2>/dev/null || module load SAMtools 2>/dev/null || echo "[$(timestamp)] No SAMtools module found, checking system PATH"
    module list -t 2>&1 | grep -i samtools || true
fi

# Verify SAMtools is available
if ! command -v samtools &> /dev/null; then
    echo "[$(timestamp)] ERROR: SAMtools is not installed or not in PATH"
    exit 1
fi

echo "[$(timestamp)] SAMtools version: $(samtools --version | head -1)"
echo

#################### Build CRAM File List ####################

print_header "Building CRAM File List"

# Create temporary file to store CRAM files
TEMP_CRAM_LIST=$(mktemp)
trap "rm -f $TEMP_CRAM_LIST" EXIT

echo "[$(timestamp)] Searching for CRAM files in: $INPUT_DIR"

# Find all CRAM files in input directory
find "$INPUT_DIR" -maxdepth 1 -name "*.cram" -type f | sort > "$TEMP_CRAM_LIST"

# Count total CRAM files
TOTAL_CRAMS=$(wc -l < "$TEMP_CRAM_LIST" | tr -d ' ' || echo "0")

if [ "$TOTAL_CRAMS" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No CRAM files found in input directory"
    exit 1
fi

echo "[$(timestamp)] Total CRAM files to process: $TOTAL_CRAMS"
echo

# Preview CRAM files based on total count
if [ "$TOTAL_CRAMS" -eq 1 ]; then
    echo "[$(timestamp)] CRAM file to process:"
    cat "$TEMP_CRAM_LIST" | while IFS= read -r cram; do
        local_size=$(format_size "$(stat --printf="%s" "$cram" 2>/dev/null || stat -f%z "$cram" 2>/dev/null || echo "0")")
        echo "  - $(basename "$cram") ($local_size)"
    done
elif [ "$TOTAL_CRAMS" -le 5 ]; then
    echo "[$(timestamp)] All $TOTAL_CRAMS CRAM files to process:"
    cat "$TEMP_CRAM_LIST" | while IFS= read -r cram; do
        local_size=$(format_size "$(stat --printf="%s" "$cram" 2>/dev/null || stat -f%z "$cram" 2>/dev/null || echo "0")")
        echo "  - $(basename "$cram") ($local_size)"
    done
else
    echo "[$(timestamp)] First 5 of $TOTAL_CRAMS CRAM files to process:"
    head -5 "$TEMP_CRAM_LIST" | while IFS= read -r cram; do
        local_size=$(format_size "$(stat --printf="%s" "$cram" 2>/dev/null || stat -f%z "$cram" 2>/dev/null || echo "0")")
        echo "  - $(basename "$cram") ($local_size)"
    done
    echo "  ... and $((TOTAL_CRAMS - 5)) more files"
fi

#################### Process CRAM Files ####################

print_header "Converting CRAM Files"

echo "[$(timestamp)] Starting CRAM to BAM conversion..."
echo

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
trap "rm -f $TEMP_CRAM_LIST $SUCCESS_LOG $FAIL_LOG" EXIT

# Record start time
JOB_START_TIME=$(date +%s)

# Process each CRAM file
while IFS= read -r input_cram || [ -n "$input_cram" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing CRAM file $CURRENT of $TOTAL_CRAMS"
    echo ""
    
    # Convert the CRAM file
    if convert_cram "$input_cram" "$OUTPUT_DIR" "$REFERENCE" "$THREADS" "$DRY_RUN" "$VERBOSE"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "$input_cram" >> "$SUCCESS_LOG"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$input_cram" >> "$FAIL_LOG"
    fi
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_CRAMS"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
    
done < "$TEMP_CRAM_LIST"

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Summary ####################

print_header "Conversion Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total CRAM files:        $TOTAL_CRAMS"
echo "  Successfully converted:  $SUCCESS_COUNT"
echo "  Failed/invalid:          $FAIL_COUNT"
echo
echo "  Input directory:         $INPUT_DIR"
echo "  Output directory:        $OUTPUT_DIR"
echo "  Reference genome:        $(basename "$REFERENCE")"
echo "  Threads used:            $THREADS"
echo "  Dry run:                 $DRY_RUN"
echo "  Total time:              $(format_duration $JOB_DURATION)"
echo

# Report successful conversions
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Successfully converted and validated:"
    while IFS= read -r cram; do
        echo "  ✓ $(basename "$cram" .cram).bam"
    done < "$SUCCESS_LOG" | head -5
    if [ "$SUCCESS_COUNT" -gt 5 ]; then
        echo "  ... and $((SUCCESS_COUNT - 5)) more"
    fi
    echo
fi

# Report failed conversions
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following CRAM files failed conversion or validation:"
    while IFS= read -r cram; do
        echo "  ✗ $(basename "$cram")"
    done < "$FAIL_LOG"
    echo
fi

# Create log file
LOG_FILE="convertedCrams.log"
{
    echo "CRAM to BAM Conversion Summary"
    echo "=============================="
    echo "Timestamp: $(timestamp)"
    echo "Input directory: $INPUT_DIR"
    echo "Output directory: $OUTPUT_DIR"
    echo "Reference genome: $REFERENCE"
    echo "Threads: $THREADS"
    echo "Dry run: $DRY_RUN"
    echo ""
    echo "Results:"
    echo "--------"
    echo "Total CRAM files: $TOTAL_CRAMS"
    echo "Successfully converted: $SUCCESS_COUNT"
    echo "Failed: $FAIL_COUNT"
    echo "Total time: $(format_duration $JOB_DURATION)"
    echo ""
    
    if [ "$SUCCESS_COUNT" -gt 0 ]; then
        echo "Successfully Converted:"
        echo "----------------------"
        while IFS= read -r cram; do
            echo "  $(basename "$cram" .cram).bam"
        done < "$SUCCESS_LOG"
        echo ""
    fi
    
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "Failed Conversions:"
        echo "------------------"
        while IFS= read -r cram; do
            echo "  $(basename "$cram")"
        done < "$FAIL_LOG"
    fi
} > "$LOG_FILE"

echo "[$(timestamp)] Log file created: $LOG_FILE"
echo

# Success summary
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "------------------------------------------------------------"
    echo "  SUCCESS: All $SUCCESS_COUNT CRAM files converted!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
elif [ "$DRY_RUN" = "true" ]; then
    echo "------------------------------------------------------------"
    echo "  DRY RUN COMPLETE: Ready to convert $SUCCESS_COUNT CRAM files"
    echo
    echo "[$(timestamp)] Dry run completed - no files were actually converted"
    exit 0
else
    echo "------------------------------------------------------------"
    echo "  PARTIAL SUCCESS: $SUCCESS_COUNT converted, $FAIL_COUNT failed"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

print_header "End of Job"