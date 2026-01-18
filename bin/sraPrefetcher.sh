#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=6G
#SBATCH --time=1-00:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-sraPrefetcher-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script prefetches SRA data from NCBI using the SRA Toolkit"
    echo "Supports both public and controlled-access (dbGaP) data"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/sraPrefetcher.sh -l [accessionList] [options]'
    echo
    echo "Required Arguments:"
    echo "  -l [accessionList]  Text file containing SRA accession IDs (one ID per line)"
    echo "                      Supports: SRR, SRX, SRS, SRP identifiers"
    echo
    echo "Optional Arguments:"
    echo "  -o [outputDir]      Output directory for prefetched files (default: current directory)"
    echo "  -n [ngcFile]        Path to .ngc file for dbGaP controlled-access data"
    echo "  -m [maxSize]        Maximum download size (default: 500G)"
    echo "  -r                  Resume incomplete downloads"
    echo "  -d                  Dry run - show what would be downloaded without actually downloading"
    echo "  -v                  Verbose output with debug logging"
    echo "  -h                  Print this help message"
    echo
    echo "File Format (for accession list):"
    echo "  - One SRA accession ID per line"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo "  - Supported formats: SRR (run), SRX (experiment), SRS (sample), SRP (project)"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Prefetch public SRA data"
    echo '  sbatch --job-name=sra-public ~/atelier/bin/sraPrefetcher.sh -l sra_accessions.txt'
    echo
    echo "  # Prefetch to specific output directory"
    echo '  sbatch --job-name=sra-download ~/atelier/bin/sraPrefetcher.sh -l sra_accessions.txt -o /data/sra_files/'
    echo
    echo "  # Prefetch controlled-access data with dbGaP key"
    echo '  sbatch --job-name=sra-dbgap ~/atelier/bin/sraPrefetcher.sh -l controlled_accessions.txt -n ~/prj_1234.ngc'
    echo
    echo "  # Prefetch with custom max size and resume enabled"
    echo '  sbatch --job-name=sra-large ~/atelier/bin/sraPrefetcher.sh -l accessions.txt -m 1T -r'
    echo
    echo "  # Dry run to preview downloads"
    echo '  sbatch --job-name=sra-preview ~/atelier/bin/sraPrefetcher.sh -l accessions.txt -d'
    echo
    echo "  # Verbose mode with debug logging"
    echo '  sbatch --job-name=sra-verbose ~/atelier/bin/sraPrefetcher.sh -l accessions.txt -v'
    echo
    echo "Notes:"
    echo "  - The SRA Toolkit must be available (sratoolkit module)"
    echo "  - Downloaded files are stored in the output directory"
    echo "  - Use -r flag to resume interrupted downloads"
    echo "  - For dbGaP data, the .ngc file must be in your home directory or absolute path"
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

# Function to validate SRA accession format
validate_sra_accession() {
    local accession="$1"
    
    # Valid SRA accession formats: SRR, SRX, SRS, SRP (followed by 6-10 digits)
    if [[ "$accession" =~ ^(SRR|SRX|SRS|SRP|ERR|ERX|ERS|ERP|DRR|DRX|DRS|DRP)[0-9]{6,10}$ ]]; then
        return 0
    else
        return 1
    fi
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
    
    # Verify it's a valid NGC file (should contain "dbGaP" or similar indicators)
    if ! file "$ngc_path" | grep -q "text\|data"; then
        echo "[$(timestamp)] WARNING: NGC file may not be valid: $ngc_path"
    fi
    
    return 0
}

# Function to parse max size to bytes
parse_size() {
    local size_str="$1"
    local multiplier=1
    
    # Extract number and unit
    if [[ "$size_str" =~ ^([0-9]+)([KMGT]?)$ ]]; then
        local size="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        
        case "$unit" in
            K) multiplier=1024 ;;
            M) multiplier=$((1024 * 1024)) ;;
            G) multiplier=$((1024 * 1024 * 1024)) ;;
            T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
        esac
        
        echo $((size * multiplier))
    else
        echo "$size_str"
    fi
}

# Function to prefetch a single SRA accession
prefetch_accession() {
    local accession="$1"
    local output_dir="$2"
    local ngc_file="$3"
    local resume="$4"
    local max_size="$5"
    local dry_run="$6"
    local verbose="$7"
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would prefetch: $accession"
        if [ -n "$ngc_file" ]; then
            echo "[$(timestamp)] [DRY RUN] Using NGC file: $ngc_file (controlled access)"
        fi
        return 0
    fi
    
    echo "[$(timestamp)] Prefetching: $accession"
    
    # Build prefetch command
    local prefetch_cmd="prefetch"
    
    # Add flags
    prefetch_cmd="$prefetch_cmd --progress"
    
    if [ "$resume" = "true" ]; then
        prefetch_cmd="$prefetch_cmd --resume yes"
    fi
    
    if [ -n "$max_size" ]; then
        prefetch_cmd="$prefetch_cmd --max-size $max_size"
    fi
    
    if [ "$verbose" = "true" ]; then
        prefetch_cmd="$prefetch_cmd --log-level debug"
    else
        prefetch_cmd="$prefetch_cmd --log-level info"
    fi
    
    # Add NGC file if provided
    if [ -n "$ngc_file" ]; then
        prefetch_cmd="$prefetch_cmd --ngc \"$ngc_file\""
    fi
    
    # Add output directory
    if [ -n "$output_dir" ]; then
        prefetch_cmd="$prefetch_cmd -O \"$output_dir\""
    fi
    
    # Add accession
    prefetch_cmd="$prefetch_cmd \"$accession\""
    
    echo "[$(timestamp)] Command: $prefetch_cmd"
    
    # Execute prefetch
    local start_time
    start_time=$(date +%s)
    
    if eval "$prefetch_cmd" 2>&1; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local formatted_duration
        formatted_duration=$(format_duration "$duration")
        
        echo "[$(timestamp)] SUCCESS: $accession (completed in $formatted_duration)"
        return 0
    else
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local formatted_duration
        formatted_duration=$(format_duration "$duration")
        
        echo "[$(timestamp)] FAILED: $accession (attempted for $formatted_duration)"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
ACCESSION_LIST=""
OUTPUT_DIR=""
NGC_FILE=""
MAX_SIZE="500G"
RESUME="false"
DRY_RUN="false"
VERBOSE="false"

# Parse command line options
while getopts ":hl:o:n:m:rdv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        l) # Accession list
            ACCESSION_LIST="$OPTARG"
            ;;
        o) # Output directory
            OUTPUT_DIR="$OPTARG"
            ;;
        n) # NGC file
            NGC_FILE="$OPTARG"
            ;;
        m) # Max size
            MAX_SIZE="$OPTARG"
            ;;
        r) # Resume mode
            RESUME="true"
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

print_header "SRA Prefetcher"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"
echo

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

echo "[$(timestamp)] Accession list: $ACCESSION_LIST"

# Process output directory
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(pwd)"
    echo "[$(timestamp)] Output directory not specified, using current directory"
else
    OUTPUT_DIR=$(get_absolute_path "$OUTPUT_DIR")
    
    if [ ! -d "$OUTPUT_DIR" ]; then
        echo "[$(timestamp)] Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
fi

echo "[$(timestamp)] Output directory: $OUTPUT_DIR"

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

# Parse and display max size
PARSED_MAX_SIZE=$(parse_size "$MAX_SIZE")
echo "[$(timestamp)] Maximum download size: $MAX_SIZE ($(format_size "$PARSED_MAX_SIZE"))"

echo "[$(timestamp)] Resume incomplete downloads: $RESUME"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Verbose logging: $VERBOSE"

#################### Load SRA Toolkit ####################

print_header "Environment Setup"

# Try to load SRA Toolkit module
if command -v module &> /dev/null; then
    echo "[$(timestamp)] Loading SRA Toolkit module..."
    module load sratoolkit 2>/dev/null || module load sra-toolkit 2>/dev/null || echo "[$(timestamp)] No SRA Toolkit module found, checking system PATH"
    module list -t 2>&1 | grep -i sra || true
fi

# Verify SRA Toolkit is available
if ! command -v prefetch &> /dev/null; then
    echo "[$(timestamp)] ERROR: SRA Toolkit (prefetch) is not installed or not in PATH"
    exit 1
fi

echo "[$(timestamp)] SRA Toolkit version: $(prefetch --version 2>&1 | head -1)"
echo

# Configure vdb-config to download to output directory
if [ "$DRY_RUN" = "false" ]; then
    echo "[$(timestamp)] Configuring vdb-config for output directory..."
    vdb-config --prefetch-to-cwd
fi

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

echo "[$(timestamp)] Total accessions to prefetch: $TOTAL_ACCESSIONS"
echo

# Preview first few accessions
echo "[$(timestamp)] First 10 accessions to prefetch:"
head -10 "$TEMP_ACCESSION_LIST" | while IFS= read -r accession; do
    echo "  - $accession"
done
if [ "$TOTAL_ACCESSIONS" -gt 10 ]; then
    echo "  ... and $((TOTAL_ACCESSIONS - 10)) more accessions"
fi

#################### Process Accessions ####################

print_header "Prefetching SRA Data"

echo "[$(timestamp)] Starting prefetch process..."
echo

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
    
    # Prefetch the accession
    if prefetch_accession "$accession" "$OUTPUT_DIR" "$NGC_FILE" "$RESUME" "$MAX_SIZE" "$DRY_RUN" "$VERBOSE"; then
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

print_header "Prefetch Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total accessions:      $TOTAL_ACCESSIONS"
echo "  Successful:            $SUCCESS_COUNT"
echo "  Failed:                $FAIL_COUNT"
echo
echo "  Output directory:      $OUTPUT_DIR"
echo "  Maximum size per file: $MAX_SIZE"
echo "  Resume enabled:        $RESUME"
echo "  Controlled access:     $([ -n "$NGC_FILE" ] && echo "Yes" || echo "No")"
echo "  Dry run:               $DRY_RUN"
echo "  Total time:            $(format_duration $JOB_DURATION)"
echo

# Report successful accessions
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Successfully prefetched:"
    while IFS= read -r accession; do
        echo "  ✓ $accession"
    done < "$SUCCESS_LOG" | head -5
    if [ "$SUCCESS_COUNT" -gt 5 ]; then
        echo "  ... and $((SUCCESS_COUNT - 5)) more"
    fi
    echo
fi

# Report failed accessions if any
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following accessions failed to prefetch:"
    while IFS= read -r accession; do
        echo "  ✗ $accession"
    done < "$FAIL_LOG"
    echo
fi

# Success summary
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "-------------------------------------------------------------"
    echo "  SUCCESS: All $SUCCESS_COUNT accessions prefetched!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
else
    echo "-------------------------------------------------------------"
    echo "  PARTIAL SUCCESS: $SUCCESS_COUNT prefetched, $FAIL_COUNT failed"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

print_header "End of Job"
