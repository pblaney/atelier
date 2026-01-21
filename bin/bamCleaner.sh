#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=4G
#SBATCH --time=3-00:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-bamCleaner-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script cleans up BAM files by fixing MAPQ issues in unmapped reads"
    echo "and automatically validates BAM file integrity"
    echo
    echo "Features:"
    echo "  - Filters unmapped reads with non-zero MAPQ (sets MAPQ to 0)"
    echo "  - Removes unmapped reads entirely (optional)"
    echo "  - Automatically validates BAM file integrity after cleaning"
    echo "  - Multi-threaded processing"
    echo "  - Batch processing support"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/bamCleaner.sh -i [input] [options]'
    echo
    echo "Required Arguments:"
    echo "  -i [input]      Input BAM file or file list"
    echo "                  Can be single BAM or text file with one path per line"
    echo
    echo "Optional Arguments:"
    echo "  -o [outputDir]  Output directory for cleaned BAMs (default: same as input)"
    echo "  -p [prefix]     Output filename prefix (default: original_name.cleaned)"
    echo "  -t [threads]    Number of threads to use (default: auto-detect)"
    echo "  -r              Remove unmapped reads entirely (default: keep with MAPQ=0)"
    echo "  -n              Dry run - show what would be processed"
    echo "  -v              Verbose output with detailed validation"
    echo "  -h              Print this help message"
    echo
    echo "File List Format (for batch processing):"
    echo "  - One BAM file path per line (absolute or relative)"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Clean a single BAM file (with automatic validation)"
    echo '  sbatch --job-name=clean-bam ~/atelier/bin/bamCleaner.sh -i sample.bam'
    echo
    echo "  # Remove unmapped reads entirely"
    echo '  sbatch --job-name=clean-remove ~/atelier/bin/bamCleaner.sh -i sample.bam -r'
    echo
    echo "  # Batch clean multiple BAM files"
    echo '  sbatch --job-name=clean-batch ~/atelier/bin/bamCleaner.sh -i bam_list.txt'
    echo
    echo "  # Custom output directory and prefix"
    echo '  sbatch --job-name=clean-custom ~/atelier/bin/bamCleaner.sh -i sample.bam -o /data/cleaned/ -p sample.v2'
    echo
    echo "  # Use specific number of threads"
    echo '  sbatch --job-name=clean-threads ~/atelier/bin/bamCleaner.sh -i sample.bam -t 8'
    echo
    echo "  # Verbose output with detailed validation"
    echo '  sbatch --job-name=clean-verbose ~/atelier/bin/bamCleaner.sh -i sample.bam -v'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=clean-preview ~/atelier/bin/bamCleaner.sh -i sample.bam -n'
    echo
    echo "Output File Naming:"
    echo "  - Default: [original_name].cleaned.bam"
    echo "  - Custom prefix: [prefix].bam"
    echo
    echo "Notes:"
    echo "  - SAMtools must be available (samtools module)"
    echo "  - Output BAM files are automatically validated and indexed"
    echo "  - Original files are never modified"
    echo "  - Validation includes integrity check and read statistics"
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

# Function to get number of CPU cores
get_cpu_count() {
    if command -v nproc &> /dev/null; then
        nproc
    elif [ -f /proc/cpuinfo ]; then
        grep -c "^processor" /proc/cpuinfo
    else
        echo "1"
    fi
}

# Function to validate BAM file (required after cleaning)
validate_bam() {
    local bam_file="$1"
    local verbose="$2"
    
    if [ ! -f "$bam_file" ]; then
        echo "[$(timestamp)] ERROR: BAM file not found: $bam_file"
        return 1
    fi
    
    echo "[$(timestamp)] Validating BAM: $(basename "$bam_file")"
    
    # Check for valid header
    if samtools view -H "$bam_file" 2>/dev/null | grep -q "^@HD"; then
        echo "[$(timestamp)]   ✓ Valid SAM header detected"
    else
        echo "[$(timestamp)] WARNING: Could not detect SAM header"
    fi
    
    # Quick check for file integrity
    if ! samtools quickcheck "$bam_file" 2>/dev/null; then
        echo "[$(timestamp)] ✗ Quick check FAILED - BAM file is corrupted"
        return 1
    fi
    
    echo "[$(timestamp)] ✓ Quick check PASSED"
    
    # Count reads
    local read_count
    read_count=$(samtools view -c "$bam_file" 2>/dev/null)
    echo "[$(timestamp)]   Total reads: $read_count"
    
    # Verbose validation
    if [ "$verbose" = "true" ]; then
        echo "[$(timestamp)] Running extended validation..."
        
        # Check for read duplicates
        local duplicate_count
        duplicate_count=$(samtools view -c -F 1024 "$bam_file" 2>/dev/null || echo "0")
        echo "[$(timestamp)]   Non-duplicate reads: $duplicate_count"
        
        # Check secondary alignments
        local secondary_count
        secondary_count=$(samtools view -c -f 256 "$bam_file" 2>/dev/null || echo "0")
        echo "[$(timestamp)]   Secondary alignments: $secondary_count"
        
        # Validate all reads
        echo "[$(timestamp)]   Running full BAM validation (this may take a moment)..."
        local validation_output
        validation_output=$(samtools view -c "$bam_file" 2>&1 | tail -1)
        if [[ "$validation_output" =~ ^[0-9]+$ ]]; then
            echo "[$(timestamp)] ✓ Full validation completed successfully"
        else
            echo "[$(timestamp)] WARNING: Could not complete full validation"
        fi
    fi
    
    return 0
}

# Function to get BAM file statistics
get_bam_stats() {
    local bam_file="$1"
    
    local file_size
    file_size=$(stat --printf="%s" "$bam_file" 2>/dev/null || stat -f%z "$bam_file" 2>/dev/null || echo "0")
    
    local read_count
    read_count=$(samtools view -c "$bam_file" 2>/dev/null || echo "0")
    
    echo "$file_size|$read_count"
}

# Function to clean a single BAM file
clean_bam() {
    local input_bam="$1"
    local output_bam="$2"
    local threads="$3"
    local remove_unmapped="$4"
    local dry_run="$5"
    local verbose="$6"
    
    # Get file statistics
    local input_stats
    input_stats=$(get_bam_stats "$input_bam")
    local input_size
    local input_reads
    IFS='|' read -r input_size input_reads <<< "$input_stats"
    
    local formatted_input_size
    formatted_input_size=$(format_size "$input_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would clean: $(basename "$input_bam") ($formatted_input_size, $input_reads reads)"
        if [ "$remove_unmapped" = "true" ]; then
            echo "[$(timestamp)] [DRY RUN] Mode: Remove unmapped reads entirely"
        else
            echo "[$(timestamp)] [DRY RUN] Mode: Fix MAPQ for unmapped reads (set to 0)"
        fi
        echo "[$(timestamp)] [DRY RUN] Output: $(basename "$output_bam")"
        echo "[$(timestamp)] [DRY RUN] Threads: $threads"
        echo "[$(timestamp)] [DRY RUN] Validation: Automatic (always performed)"
        return 0
    fi
    
    echo "[$(timestamp)]   Processing: $(basename "$input_bam")"
    echo "[$(timestamp)]   Input size: $formatted_input_size"
    echo "[$(timestamp)]   Total reads: $input_reads"
    echo "[$(timestamp)]   Threads: $threads"
    
    # Build samtools command
    local samtools_cmd="samtools view"
    
    # Add multi-threading
    samtools_cmd="$samtools_cmd -@ $threads"
    
    # Output as BAM with header
    samtools_cmd="$samtools_cmd -hb"
    
    # Filter unmapped reads with non-zero MAPQ
    if [ "$remove_unmapped" = "true" ]; then
        # -F 4: exclude unmapped reads
        samtools_cmd="$samtools_cmd -F 4"
        echo "[$(timestamp)] Mode: Remove unmapped reads"
    else
        # Keep all reads but fix MAPQ for unmapped ones
        echo "[$(timestamp)] Mode: Fix MAPQ for unmapped reads (set to 0)"
    fi
    
    local start_time
    start_time=$(date +%s)
    
    # Execute cleaning
    if [ "$remove_unmapped" = "true" ]; then
        # Simple case: just filter out unmapped reads
        if ! eval "$samtools_cmd \"$input_bam\" > \"$output_bam\""; then
            echo "[$(timestamp)] FAILED: SAMtools filtering failed"
            return 1
        fi
    else
        # Complex case: fix MAPQ for unmapped reads
        # Use samtools with additional processing
        if ! samtools view -h "$input_bam" \
            | awk 'BEGIN {FS=OFS="\t"} /^@/ {print; next} $2 ~ /[46]/ {$5=0} {print}' \
            | samtools view -@ "$threads" -b -o "$output_bam" - 2>/dev/null; then
            echo "[$(timestamp)] FAILED: BAM cleaning failed"
            return 1
        fi
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    # Index the output BAM
    echo "[$(timestamp)] Indexing output BAM..."
    if ! samtools index -@ "$threads" "$output_bam" 2>/dev/null; then
        echo "[$(timestamp)] WARNING: Failed to create BAM index"
        return 1
    fi
    echo "[$(timestamp)] ✓ Index created"
    
    # Get output statistics
    local output_stats
    output_stats=$(get_bam_stats "$output_bam")
    local output_size
    local output_reads
    IFS='|' read -r output_size output_reads <<< "$output_stats"
    
    local formatted_output_size
    formatted_output_size=$(format_size "$output_size")
    
    echo "[$(timestamp)] SUCCESS: Cleaned BAM created"
    echo "[$(timestamp)]   Output size: $formatted_output_size"
    echo "[$(timestamp)]   Output reads: $output_reads"
    echo "[$(timestamp)]   Cleaning time: $formatted_duration"
    
    # Automatic validation after cleaning
    echo "[$(timestamp)] Running automatic validation..."
    if validate_bam "$output_bam" "$verbose"; then
        echo "[$(timestamp)] ✓✓✓ BAM validation PASSED - File is ready to use"
        return 0
    else
        echo "[$(timestamp)] ✗✗✗ BAM validation FAILED - File may be corrupted"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
INPUT=""
OUTPUT_DIR=""
OUTPUT_PREFIX=""
THREADS=""
REMOVE_UNMAPPED="false"
DRY_RUN="false"
VERBOSE="false"

# Parse command line options
while getopts ":hi:o:p:t:rnv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        i) # Input BAM or list
            INPUT="$OPTARG"
            ;;
        o) # Output directory
            OUTPUT_DIR="$OPTARG"
            ;;
        p) # Output prefix
            OUTPUT_PREFIX="$OPTARG"
            ;;
        t) # Threads
            THREADS="$OPTARG"
            ;;
        r) # Remove unmapped
            REMOVE_UNMAPPED="true"
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

print_header "BAM Cleaner"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"
echo

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if input is provided
if [ -z "$INPUT" ]; then
    echo "[$(timestamp)] ERROR: Input BAM file or list (-i) is required"
    Help
    exit 1
fi

# Determine if input is a single file or list
if [ -f "$INPUT" ]; then
    # Check if it's a BAM file or text list
    if [[ "$INPUT" == *.bam ]]; then
        INPUT_TYPE="single"
        INPUT=$(get_absolute_path "$INPUT")
        echo "[$(timestamp)] Input: Single BAM file"
        echo "[$(timestamp)] File: $INPUT"
    else
        INPUT_TYPE="list"
        INPUT=$(get_absolute_path "$INPUT")
        echo "[$(timestamp)] Input: BAM file list"
        echo "[$(timestamp)] File: $INPUT"
    fi
else
    echo "[$(timestamp)] ERROR: Input file not found: $INPUT"
    exit 1
fi

# Set up output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$(dirname "$INPUT")
    echo "[$(timestamp)] Output directory not specified, using input directory"
else
    OUTPUT_DIR=$(get_absolute_path "$OUTPUT_DIR")
    if [ ! -d "$OUTPUT_DIR" ]; then
        echo "[$(timestamp)] Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
fi

echo "[$(timestamp)] Output directory: $OUTPUT_DIR"

# Set up thread count
if [ -z "$THREADS" ]; then
    THREADS=$(get_cpu_count)
    echo "[$(timestamp)] Auto-detected thread count: $THREADS"
else
    # Validate thread count
    if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [ "$THREADS" -lt 1 ]; then
        echo "[$(timestamp)] ERROR: Invalid thread count: $THREADS"
        exit 1
    fi
fi

echo "[$(timestamp)] Threads to use: $THREADS"
echo "[$(timestamp)] Remove unmapped reads: $REMOVE_UNMAPPED"
echo "[$(timestamp)] Validation: Automatic (always performed)"
echo "[$(timestamp)] Verbose output: $VERBOSE"
echo "[$(timestamp)] Dry run: $DRY_RUN"

#################### Load SAMtools ####################

print_header "Environment Setup"

# Try to load SAMtools module
if command -v module &> /dev/null; then
    echo "[$(timestamp)] Loading SAMtools module..."
    module load samtools/1.20 2>/dev/null || module load SAMtools 2>/dev/null || echo "[$(timestamp)] No SAMtools module found, checking system PATH"
    module list -t 2>&1 | grep -i samtools || true
fi

# Verify SAMtools is available
if ! command -v samtools &> /dev/null; then
    echo "[$(timestamp)] ERROR: SAMtools is not installed or not in PATH"
    exit 1
fi

echo "[$(timestamp)] SAMtools version: $(samtools --version | head -1)"
echo

#################### Build BAM File List ####################

print_header "Building BAM File List"

# Create temporary file to store BAM files
TEMP_BAM_LIST=$(mktemp)
trap "rm -f $TEMP_BAM_LIST" EXIT

if [ "$INPUT_TYPE" = "single" ]; then
    # Single BAM file
    echo "[$(timestamp)] Processing single BAM file"
    echo "$INPUT" >> "$TEMP_BAM_LIST"
else
    # BAM file list
    echo "[$(timestamp)] Reading BAM file list"
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        line=$(echo "$line" | xargs)
        
        # Convert to absolute path
        local_bam=$(get_absolute_path "$line")
        
        # Verify file exists and is BAM
        if [ ! -f "$local_bam" ]; then
            echo "[$(timestamp)] WARNING: BAM file not found: $local_bam"
            continue
        fi
        
        if [[ ! "$local_bam" == *.bam ]]; then
            echo "[$(timestamp)] WARNING: Not a BAM file: $local_bam"
            continue
        fi
        
        echo "$local_bam" >> "$TEMP_BAM_LIST"
    done < "$INPUT"
fi

# Count total BAM files
TOTAL_BAMS=$(wc -l < "$TEMP_BAM_LIST" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$TOTAL_BAMS" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No valid BAM files to process"
    exit 1
fi

echo "[$(timestamp)] Total BAM files to process: $TOTAL_BAMS"
echo

# Preview first few BAM files
echo "[$(timestamp)] First 5 BAM files to process:"
head -5 "$TEMP_BAM_LIST" | while IFS= read -r bam; do
    local_size=$(format_size "$(stat --printf="%s" "$bam" 2>/dev/null || stat -f%z "$bam" 2>/dev/null || echo "0")")
    echo "  - $(basename "$bam") ($local_size)"
done
if [ "$TOTAL_BAMS" -gt 5 ]; then
    echo "  ... and $((TOTAL_BAMS - 5)) more files"
fi

#################### Process BAM Files ####################

print_header "Cleaning BAM Files"

echo "[$(timestamp)] Starting BAM cleaning..."
echo "[$(timestamp)] All output files will be automatically validated"
echo

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
trap "rm -f $TEMP_BAM_LIST $SUCCESS_LOG $FAIL_LOG" EXIT

# Record start time
JOB_START_TIME=$(date +%s)

# Process each BAM file
while IFS= read -r input_bam || [ -n "$input_bam" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing BAM file $CURRENT of $TOTAL_BAMS"
    echo ""
    
    # Determine output filename
    local_bam_base=$(basename "$input_bam" .bam)
    
    if [ -n "$OUTPUT_PREFIX" ]; then
        output_bam="${OUTPUT_DIR}/${OUTPUT_PREFIX}.bam"
    else
        output_bam="${OUTPUT_DIR}/${local_bam_base}.cleaned.bam"
    fi
    
    echo "[$(timestamp)] Output: $(basename "$output_bam")"
    
    # Clean the BAM file (validation is automatic)
    if clean_bam "$input_bam" "$output_bam" "$THREADS" "$REMOVE_UNMAPPED" "$DRY_RUN" "$VERBOSE"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "$input_bam" >> "$SUCCESS_LOG"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$input_bam" >> "$FAIL_LOG"
    fi
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_BAMS"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
    
done < "$TEMP_BAM_LIST"

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Summary ####################

print_header "Cleaning Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total BAM files:       $TOTAL_BAMS"
echo "  Successfully validated: $SUCCESS_COUNT"
echo "  Failed/invalid:         $FAIL_COUNT"
echo
echo "  Output directory:      $OUTPUT_DIR"
echo "  Mode:                  $([ "$REMOVE_UNMAPPED" = "true" ] && echo "Remove unmapped" || echo "Fix MAPQ")"
echo "  Validation:            Automatic (always performed)"
echo "  Threads used:          $THREADS"
echo "  Dry run:               $DRY_RUN"
echo "  Total time:            $(format_duration $JOB_DURATION)"
echo

# Report successful files
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Successfully cleaned and validated:"
    while IFS= read -r bam; do
        echo "  ✓ $(basename "$bam")"
    done < "$SUCCESS_LOG" | head -5
    if [ "$SUCCESS_COUNT" -gt 5 ]; then
        echo "  ... and $((SUCCESS_COUNT - 5)) more"
    fi
    echo
fi

# Report failed files if any
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following BAM files failed cleaning or validation:"
    while IFS= read -r bam; do
        echo "  ✗ $(basename "$bam")"
    done < "$FAIL_LOG"
    echo
fi

# Success summary
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "------------------------------------------------------------"
    echo "  SUCCESS: All $SUCCESS_COUNT BAM files cleaned and validated!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
else
    echo "------------------------------------------------------------"
    echo "  PARTIAL SUCCESS: $SUCCESS_COUNT validated, $FAIL_COUNT failed"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

print_header "End of Job"
