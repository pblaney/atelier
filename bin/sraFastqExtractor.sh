#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem-per-cpu=4G
#SBATCH --time=5-00:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-sraFastqExtractor-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script extracts FASTQ files from prefetched SRA data using fasterq-dump"
    echo "Supports both public and controlled-access (dbGaP) data"
    echo
    echo "Features:"
    echo "  - Extract FASTQ files from SRA accessions"
    echo "  - Support for controlled-access data with dbGaP keys"
    echo "  - Automatic gzip compression of output FASTQs"
    echo "  - Multi-threaded processing (8 threads, 4GB memory)"
    echo "  - Batch processing from accession list"
    echo "  - Temporary file cleanup"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l [accessionList] [options]'
    echo
    echo "Required Arguments:"
    echo "  -l [accessionList]  Text file containing SRA accession IDs (one ID per line)"
    echo "                      Assumes accessions are in subdirectories with prefetched .sra files"
    echo
    echo "Optional Arguments:"
    echo "  -b [baseDir]        Base directory containing accession subdirectories"
    echo "                      (default: current working directory)"
    echo "  -n [ngcFile]        Path to .ngc file for dbGaP controlled-access data"
    echo "  -d                  Dry run - show what would be processed"
    echo "  -v                  Verbose output"
    echo "  -h                  Print this help message"
    echo
    echo "File Format (for accession list):"
    echo "  - One SRA accession ID per line"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo "  - Each accession should have a subdirectory with the prefetched .sra file"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Basic FASTQ extraction from public data"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l accessions.txt'
    echo
    echo "  # Extract controlled-access data with dbGaP key"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l accessions.txt -n ~/prj_1234.ngc'
    echo
    echo "  # Specify base directory"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l accessions.txt -b /data/sra/'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l accessions.txt -d'
    echo
    echo "  # Verbose mode"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l accessions.txt -v'
    echo
    echo "Directory Structure:"
    echo "  Expected layout:"
    echo "    base_dir/"
    echo "    ├── SRR1234567/"
    echo "    │   └── SRR1234567.sra"
    echo "    ├── SRR1234568/"
    echo "    │   └── SRR1234568.sra"
    echo "    └── SRR1234569/"
    echo "        └── SRR1234569.sra"
    echo
    echo "Output:"
    echo "  - FASTQ files (gzipped) in each accession directory"
    echo "  - Log file: extractedFastq.log (created in current directory)"
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

# Function to validate NGC file
validate_ngc_file() {
    local ngc_path="$1"
    
    # Convert to absolute path if needed
    if [[ "$ngc_path" != /* ]]; then
        ngc_path="$HOME/${ngc_path}"
    fi
    
    if [ ! -f "$ngc_path" ]; then
        echo "[$(timestamp)] ERROR: NGC file not found: $ngc_path"
        return 1
    fi
    
    return 0
}

# Function to validate SRA accession format
validate_sra_accession() {
    local accession="$1"
    
    # Valid SRA accession formats: SRR, SRX, SRS, SRP, ERR, ERX, ERS, ERP, DRR, DRX, DRS, DRP
    if [[ "$accession" =~ ^(SRR|SRX|SRS|SRP|ERR|ERX|ERS|ERP|DRR|DRX|DRS|DRP)[0-9]{6,10}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to extract FASTQ from single accession
extract_fastq() {
    local base_dir="$1"
    local accession="$2"
    local ngc_file="$3"
    local threads="$4"
    local memory="$5"
    local dry_run="$6"
    local verbose="$7"
    
    local accession_dir="${base_dir}/${accession}"
    
    # Check if accession directory exists
    if [ ! -d "$accession_dir" ]; then
        echo "[$(timestamp)] ERROR: Accession directory not found: $accession_dir"
        return 1
    fi
    
    # Check if .sra file exists
    local sra_file="${accession_dir}/${accession}.sra"
    if [ ! -f "$sra_file" ]; then
        echo "[$(timestamp)] ERROR: SRA file not found: $sra_file"
        return 1
    fi
    
    local sra_size
    sra_size=$(stat --printf="%s" "$sra_file" 2>/dev/null || stat -f%z "$sra_file" 2>/dev/null || echo "0")
    local formatted_size
    formatted_size=$(format_size "$sra_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would extract FASTQ from: $accession ($formatted_size)"
        if [ -n "$ngc_file" ]; then
            echo "[$(timestamp)] [DRY RUN] Using NGC file for controlled access"
        fi
        echo "[$(timestamp)] [DRY RUN] Threads: $threads | Memory: ${memory}G"
        return 0
    fi
    
    echo "[$(timestamp)] Processing: $accession"
    echo "[$(timestamp)]   SRA file size - $formatted_size"
    echo "[$(timestamp)]   Location - $accession_dir"
    
    # Save current directory
    local original_dir
    original_dir=$(pwd)
    
    # Change to accession directory
    if ! cd "$accession_dir"; then
        echo "[$(timestamp)] FAILED: Could not change to accession directory"
        return 1
    fi
    
    # Create temp directory
    echo "[$(timestamp)] Creating temporary directory..."
    mkdir -p tmp/
    
    local start_time
    start_time=$(date +%s)
    
    # Extract FASTQ using fasterq-dump
    echo "[$(timestamp)] Running fasterq-dump..."
    
    local fasterq_cmd="fasterq-dump \"$accession\""
    fasterq_cmd="$fasterq_cmd --mem ${memory}G"
    fasterq_cmd="$fasterq_cmd --temp tmp/"
    fasterq_cmd="$fasterq_cmd --threads $threads"
    fasterq_cmd="$fasterq_cmd --progress"
    
    if [ "$verbose" = "true" ]; then
        fasterq_cmd="$fasterq_cmd --log-level debug"
    else
        fasterq_cmd="$fasterq_cmd --log-level info"
    fi
    
    # Add NGC file if provided
    if [ -n "$ngc_file" ]; then
        fasterq_cmd="$fasterq_cmd --ngc \"$ngc_file\""
        echo "[$(timestamp)] Using NGC file for controlled access"
    fi
    
    if [ "$verbose" = "true" ]; then
        echo "[$(timestamp)] Command: $fasterq_cmd"
    fi
    
    # Execute fasterq-dump
    if ! eval "$fasterq_cmd"; then
        echo "[$(timestamp)] FAILED: fasterq-dump extraction failed"
        
        # Clean up temp directory
        echo "[$(timestamp)] Cleaning up temporary files..."
        rm -rf tmp/
        
        # Return to original directory
        cd "$original_dir"
        return 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    echo "[$(timestamp)] ✓ FASTQ extraction completed in $formatted_duration"
    
    # Compress FASTQ files
    echo "[$(timestamp)] Compressing FASTQ files with gzip..."
    if [ -n "$(find . -maxdepth 1 -name "*.fastq" -type f)" ]; then
        if gzip *.fastq; then
            echo "[$(timestamp)] ✓ Compression completed"
        else
            echo "[$(timestamp)] WARNING: Compression encountered issues"
        fi
    else
        echo "[$(timestamp)] WARNING: No FASTQ files found to compress"
    fi
    
    # Get output file sizes and count
    local fastq_count
    fastq_count=$(find . -maxdepth 1 -name "*.fastq.gz" -type f | wc -l)
    
    local total_output_size=0
    while IFS= read -r file; do
        local_size=$(stat --printf="%s" "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
        total_output_size=$((total_output_size + local_size))
    done < <(find . -maxdepth 1 -name "*.fastq.gz" -type f)
    
    local formatted_output_size
    formatted_output_size=$(format_size "$total_output_size")
    
    echo "[$(timestamp)] Output: $fastq_count FASTQ files (total size: $formatted_output_size)"
    
    # Clean up temporary directory
    echo "[$(timestamp)] Cleaning up temporary files..."
    rm -rf tmp/
    
    # Return to original directory
    cd "$original_dir"
    
    echo "[$(timestamp)] SUCCESS: $accession extraction complete"
    return 0
}

#################### Parse Arguments ####################

# Initialize variables
ACCESSION_LIST=""
BASE_DIR=""
NGC_FILE=""

# Hard-set threads and memory from SLURM header
THREADS=8
MEMORY=4

DRY_RUN="false"
VERBOSE="false"

# Parse command line options
while getopts ":hl:b:n:dv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        l) # Accession list
            ACCESSION_LIST="$OPTARG"
            ;;
        b) # Base directory
            BASE_DIR="$OPTARG"
            ;;
        n) # NGC file
            NGC_FILE="$OPTARG"
            ;;
        d) # Dry run
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

print_header "SRA FASTQ Extractor"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if accession list is provided
if [ -z "$ACCESSION_LIST" ]; then
    echo "[$(timestamp)] ERROR: Accession list (-l) is required"
    Help
    exit 1
fi

# Check if accession list exists
if [ ! -f "$ACCESSION_LIST" ]; then
    echo "[$(timestamp)] ERROR: Accession list file not found: $ACCESSION_LIST"
    exit 1
fi

ACCESSION_LIST=$(get_absolute_path "$ACCESSION_LIST")
echo "[$(timestamp)] Accession list: $ACCESSION_LIST"

# Set up base directory
if [ -z "$BASE_DIR" ]; then
    BASE_DIR="$(pwd)"
    echo "[$(timestamp)] Base directory not specified, using current directory"
else
    BASE_DIR=$(get_absolute_path "$BASE_DIR")
    if [ ! -d "$BASE_DIR" ]; then
        echo "[$(timestamp)] ERROR: Base directory not found: $BASE_DIR"
        exit 1
    fi
fi

echo "[$(timestamp)] Base directory: $BASE_DIR"

# Validate NGC file if provided
if [ -n "$NGC_FILE" ]; then
    if ! validate_ngc_file "$NGC_FILE"; then
        exit 1
    fi
    # Convert to absolute path
    if [[ "$NGC_FILE" != /* ]]; then
        NGC_FILE="$HOME/$NGC_FILE"
    fi
    echo "[$(timestamp)] NGC file (controlled access): $NGC_FILE"
fi

echo "[$(timestamp)] Threads: $THREADS (from SLURM allocation)"
echo "[$(timestamp)] Memory per thread: ${MEMORY}G (from SLURM allocation)"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Verbose output: $VERBOSE"

#################### Load SRA Toolkit ####################

print_header "Environment Setup"

# Try to load SRA Toolkit module
if command -v module &> /dev/null; then
    echo "[$(timestamp)] Loading SRA Toolkit module..."
    module load sratoolkit 2>/dev/null || module load sra-toolkit 2>/dev/null || echo "[$(timestamp)] No SRA Toolkit module found, checking system PATH"
    module list -t 2>&1 | grep -i sra || true
fi

# Verify fasterq-dump is available
if ! command -v fasterq-dump &> /dev/null; then
    echo "[$(timestamp)] ERROR: fasterq-dump is not installed or not in PATH"
    exit 1
fi

echo "[$(timestamp)] fasterq-dump version: $(fasterq-dump --version 2>&1 | head -1)"
echo

#################### Build Accession List ####################

print_header "Building Accession List"

# Create temporary file to store accessions
TEMP_ACCESSION_LIST=$(mktemp)
trap "rm -f $TEMP_ACCESSION_LIST" EXIT

echo "[$(timestamp)] Reading accessions from: $ACCESSION_LIST"

VALID_COUNT=0
INVALID_COUNT=0

while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Trim whitespace
    line=$(echo "$line" | xargs)
    
    # Validate accession format
    if validate_sra_accession "$line"; then
        echo "$line" >> "$TEMP_ACCESSION_LIST"
        VALID_COUNT=$((VALID_COUNT + 1))
    else
        echo "[$(timestamp)] WARNING: Invalid SRA accession format: $line"
        INVALID_COUNT=$((INVALID_COUNT + 1))
    fi
done < "$ACCESSION_LIST"

# Count total accessions
TOTAL_ACCESSIONS=$(wc -l < "$TEMP_ACCESSION_LIST" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$TOTAL_ACCESSIONS" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No valid SRA accessions found"
    exit 1
fi

echo "[$(timestamp)] Valid accessions: $VALID_COUNT"
if [ "$INVALID_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Invalid accessions: $INVALID_COUNT (skipped)"
fi

echo "[$(timestamp)] Total accessions to process: $TOTAL_ACCESSIONS"
echo

# Preview accessions based on total count
if [ "$TOTAL_ACCESSIONS" -eq 1 ]; then
    echo "[$(timestamp)] Accession to process:"
    cat "$TEMP_ACCESSION_LIST" | while IFS= read -r accession; do
        if [ -d "${BASE_DIR}/${accession}" ]; then
            sra_file="${BASE_DIR}/${accession}/${accession}.sra"
            if [ -f "$sra_file" ]; then
                local_size=$(format_size "$(stat --printf="%s" "$sra_file" 2>/dev/null || stat -f%z "$sra_file" 2>/dev/null || echo "0")")
                echo "  - $accession ($local_size)"
            else
                echo "  - $accession (SRA file not found)"
            fi
        else
            echo "  - $accession (directory not found)"
        fi
    done
elif [ "$TOTAL_ACCESSIONS" -le 5 ]; then
    echo "[$(timestamp)] All $TOTAL_ACCESSIONS accessions to process:"
    cat "$TEMP_ACCESSION_LIST" | while IFS= read -r accession; do
        if [ -d "${BASE_DIR}/${accession}" ]; then
            sra_file="${BASE_DIR}/${accession}/${accession}.sra"
            if [ -f "$sra_file" ]; then
                local_size=$(format_size "$(stat --printf="%s" "$sra_file" 2>/dev/null || stat -f%z "$sra_file" 2>/dev/null || echo "0")")
                echo "  - $accession ($local_size)"
            else
                echo "  - $accession (SRA file not found)"
            fi
        else
            echo "  - $accession (directory not found)"
        fi
    done
else
    echo "[$(timestamp)] First 5 of $TOTAL_ACCESSIONS accessions to process:"
    head -5 "$TEMP_ACCESSION_LIST" | while IFS= read -r accession; do
        if [ -d "${BASE_DIR}/${accession}" ]; then
            sra_file="${BASE_DIR}/${accession}/${accession}.sra"
            if [ -f "$sra_file" ]; then
                local_size=$(format_size "$(stat --printf="%s" "$sra_file" 2>/dev/null || stat -f%z "$sra_file" 2>/dev/null || echo "0")")
                echo "  - $accession ($local_size)"
            else
                echo "  - $accession (SRA file not found)"
            fi
        else
            echo "  - $accession (directory not found)"
        fi
    done
    echo "  ... and $((TOTAL_ACCESSIONS - 5)) more accessions"
fi

#################### Extract FASTQ Files ####################

print_header "Extracting FASTQ Files"

echo "[$(timestamp)] Starting FASTQ extraction process..."

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
trap "rm -f $TEMP_ACCESSION_LIST $SUCCESS_LOG $FAIL_LOG" EXIT

# Record start time
JOB_START_TIME=$(date +%s)

# Process each accession
while IFS= read -r accession || [ -n "$accession" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing accession $CURRENT of $TOTAL_ACCESSIONS"
    echo ""
    
    # Extract FASTQ from accession
    if extract_fastq "$BASE_DIR" "$accession" "$NGC_FILE" "$THREADS" "$MEMORY" "$DRY_RUN" "$VERBOSE"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "$accession" >> "$SUCCESS_LOG"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$accession" >> "$FAIL_LOG"
    fi
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_ACCESSIONS"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT"
    
done < "$TEMP_ACCESSION_LIST"

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Summary ####################

print_header "Extraction Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total accessions:       $TOTAL_ACCESSIONS"
echo "  Successfully extracted: $SUCCESS_COUNT"
echo "  Failed:                 $FAIL_COUNT"
echo
echo "  Base directory:         $BASE_DIR"
echo "  Threads:                $THREADS"
echo "  Memory per thread:      ${MEMORY}G"
echo "  Controlled access:      $([ -n "$NGC_FILE" ] && echo "Yes" || echo "No")"
echo "  Dry run:                $DRY_RUN"
echo "  Total time:             $(format_duration $JOB_DURATION)"
echo

# Report successful extractions
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Successfully extracted:"
    while IFS= read -r accession; do
        echo "  ✓ $accession"
    done < "$SUCCESS_LOG" | head -5
    if [ "$SUCCESS_COUNT" -gt 5 ]; then
        echo "  ... and $((SUCCESS_COUNT - 5)) more"
    fi
    echo
fi

# Report failed extractions
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following accessions failed to extract:"
    while IFS= read -r accession; do
        echo "  ✗ $accession"
    done < "$FAIL_LOG"
    echo
fi

# Create log file
LOG_FILE="extractedFastq.log"
{
    echo "SRA FASTQ Extraction Summary"
    echo "============================"
    echo "Timestamp: $(timestamp)"
    echo "Base directory: $BASE_DIR"
    echo "Threads: $THREADS"
    echo "Memory per thread: ${MEMORY}G"
    echo "Controlled access: $([ -n "$NGC_FILE" ] && echo "Yes" || echo "No")"
    echo "Dry run: $DRY_RUN"
    echo ""
    echo "Results:"
    echo "--------"
    echo "Total accessions: $TOTAL_ACCESSIONS"
    echo "Successfully extracted: $SUCCESS_COUNT"
    echo "Failed: $FAIL_COUNT"
    echo "Total time: $(format_duration $JOB_DURATION)"
    echo ""
    
    if [ "$SUCCESS_COUNT" -gt 0 ]; then
        echo "Successfully Extracted:"
        echo "----------------------"
        while IFS= read -r accession; do
            echo "  $accession"
        done < "$SUCCESS_LOG"
        echo ""
    fi
    
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "Failed Extractions:"
        echo "------------------"
        while IFS= read -r accession; do
            echo "  $accession"
        done < "$FAIL_LOG"
    fi
} > "$LOG_FILE"

echo "[$(timestamp)] Log file created: $LOG_FILE"
echo

# Success summary
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "-------------------------------------------------------------"
    echo "  SUCCESS: All $SUCCESS_COUNT accessions extracted!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
elif [ "$DRY_RUN" = "true" ]; then
    echo "-------------------------------------------------------------"
    echo "  DRY RUN COMPLETE: Ready to extract $SUCCESS_COUNT accessions"
    echo
    echo "[$(timestamp)] Dry run completed - no files were actually extracted"
    exit 0
else
    echo "-------------------------------------------------------------"
    echo "  PARTIAL SUCCESS: $SUCCESS_COUNT extracted, $FAIL_COUNT failed"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

print_header "End of Job"
