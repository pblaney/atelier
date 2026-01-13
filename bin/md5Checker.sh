#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=2G
#SBATCH --time=8:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-md5Checker-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script calculates MD5 checksums for files or verifies files against existing checksums"
    echo "It supports batch processing via file patterns, file lists, or directory recursion"
    echo
    echo "Modes:"
    echo "  Generate (default) - Calculate MD5 checksums and save to output file"
    echo "  Verify (-v)        - Check files against existing checksum file"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/md5Checker.sh [options] -o [output]'
    echo
    echo "Required Arguments (one of the following):"
    echo "  -p [pattern]    File pattern/glob to match files (e.g., '*.bam', 'sample_*.fastq.gz')"
    echo "  -f [fileList]   Text file containing list of file paths (one per line)"
    echo "  -s [source]     Source directory to process"
    echo
    echo "Output Arguments:"
    echo "  -o [output]     Output checksum file name (without extension)"
    echo "                  In generate mode: creates md5sums-[output].txt"
    echo "                  In verify mode: this is the existing checksum file to verify against"
    echo
    echo "Optional Arguments:"
    echo "  -v              Verify mode - check files against existing checksum file"
    echo "  -r              Recursive mode - process all files in subdirectories"
    echo "  -n              Dry run - show what would be processed without calculating checksums"
    echo "  -a              Append to existing checksum file (generate mode only)"
    echo "  -h              Print this help message"
    echo
    echo "File List Format (for -f option):"
    echo "  - One file path per line (absolute or relative)"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Generate checksums for all BAM files in current directory"
    echo '  sbatch --job-name=md5-bams ~/atelier/bin/md5Checker.sh -p "*.bam" -o my_bams'
    echo '  # Creates: md5sums-my_bams.txt'
    echo
    echo "  # Generate checksums for files listed in a text file"
    echo '  sbatch --job-name=md5-list ~/atelier/bin/md5Checker.sh -f files_to_check.txt -o project_files'
    echo
    echo "  # Generate checksums recursively for a directory"
    echo '  sbatch --job-name=md5-dir ~/atelier/bin/md5Checker.sh -s /data/project/ -r -o project_backup'
    echo
    echo "  # Verify files against existing checksum file"
    echo '  sbatch --job-name=md5-verify ~/atelier/bin/md5Checker.sh -v -o md5sums-my_bams.txt'
    echo
    echo "  # Verify specific files against checksum file"
    echo '  sbatch --job-name=md5-verify ~/atelier/bin/md5Checker.sh -v -p "*.bam" -o md5sums-my_bams.txt'
    echo
    echo "  # Dry run to preview files that would be processed"
    echo '  sbatch --job-name=md5-preview ~/atelier/bin/md5Checker.sh -p "*.fastq.gz" -o test -n'
    echo
    echo "  # Append checksums to existing file"
    echo '  sbatch --job-name=md5-append ~/atelier/bin/md5Checker.sh -p "*.bam" -o existing_checksums -a'
    echo
    echo "Checksum File Format:"
    echo "  The output file follows standard md5sum format:"
    echo "  <32-character-hash>  <filename>"
    echo "  e.g., d41d8cd98f00b204e9800998ecf8427e  sample1.bam"
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
    
    if [ "$size" -ge 1073741824 ]; then
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

# Function to convert local path to absolute path
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

# Function to get file size
get_file_size() {
    local path="$1"
    
    if [ -f "$path" ]; then
        # Try GNU stat first, then BSD stat
        stat --printf="%s" "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Function to calculate MD5 checksum for a single file
calculate_md5() {
    local file_path="$1"
    local dry_run="$2"
    
    local filename
    filename=$(basename "$file_path")
    local file_size
    file_size=$(get_file_size "$file_path")
    local formatted_size
    formatted_size=$(format_size "$file_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would calculate MD5 for: $file_path ($formatted_size)"
        echo "dry_run_hash_placeholder  $file_path"
        return 0
    fi
    
    echo "[$(timestamp)] Calculating MD5 for: $file_path ($formatted_size)"
    
    local start_time
    start_time=$(date +%s)
    
    # Calculate MD5 - handle both GNU and BSD md5sum
    local md5_result
    if command -v md5sum &> /dev/null; then
        md5_result=$(md5sum "$file_path")
    elif command -v md5 &> /dev/null; then
        # BSD md5 has different output format, convert it
        local hash
        hash=$(md5 -q "$file_path")
        md5_result="$hash  $file_path"
    else
        echo "[$(timestamp)] ERROR: No md5sum or md5 command found"
        return 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    # Extract just the hash for display
    local hash
    hash=$(echo "$md5_result" | awk '{print $1}')
    
    echo "[$(timestamp)] SUCCESS: $filename"
    echo "[$(timestamp)]   Hash: $hash"
    echo "[$(timestamp)]   Time: $formatted_duration"
    
    # Return the full md5sum line
    echo "$md5_result"
    return 0
}

# Function to verify MD5 checksum for a single file
verify_md5() {
    local file_path="$1"
    local expected_hash="$2"
    local dry_run="$3"
    
    local filename
    filename=$(basename "$file_path")
    local file_size
    file_size=$(get_file_size "$file_path")
    local formatted_size
    formatted_size=$(format_size "$file_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would verify: $file_path ($formatted_size)"
        echo "[$(timestamp)] [DRY RUN] Expected hash: $expected_hash"
        return 0
    fi
    
    echo "[$(timestamp)] Verifying: $file_path ($formatted_size)"
    echo "[$(timestamp)] Expected:  $expected_hash"
    
    local start_time
    start_time=$(date +%s)
    
    # Calculate actual MD5
    local actual_hash
    if command -v md5sum &> /dev/null; then
        actual_hash=$(md5sum "$file_path" | awk '{print $1}')
    elif command -v md5 &> /dev/null; then
        actual_hash=$(md5 -q "$file_path")
    else
        echo "[$(timestamp)] ERROR: No md5sum or md5 command found"
        return 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$duration")
    
    echo "[$(timestamp)] Actual:    $actual_hash"
    echo "[$(timestamp)] Time:      $formatted_duration"
    
    # Compare hashes (case-insensitive)
    if [[ "${actual_hash,,}" == "${expected_hash,,}" ]]; then
        echo "[$(timestamp)] PASSED: $filename - checksums match"
        return 0
    else
        echo "[$(timestamp)] FAILED: $filename - checksums DO NOT match!"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
FILE_PATTERN=""
FILE_LIST=""
SOURCE_DIR=""
OUTPUT_FILE=""
VERIFY_MODE="false"
RECURSIVE="false"
DRY_RUN="false"
APPEND_MODE="false"

# Parse command line options
while getopts ":hp:f:s:o:vrna" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        p) # File pattern
            FILE_PATTERN="$OPTARG"
            ;;
        f) # File list
            FILE_LIST="$OPTARG"
            ;;
        s) # Source directory
            SOURCE_DIR="$OPTARG"
            ;;
        o) # Output file
            OUTPUT_FILE="$OPTARG"
            ;;
        v) # Verify mode
            VERIFY_MODE="true"
            ;;
        r) # Recursive mode
            RECURSIVE="true"
            ;;
        n) # Dry run
            DRY_RUN="true"
            ;;
        a) # Append mode
            APPEND_MODE="true"
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

print_header "MD5 Checksum Tool"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"
echo

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if output is provided
if [ -z "$OUTPUT_FILE" ]; then
    echo "[$(timestamp)] ERROR: Output file (-o) is required"
    Help
    exit 1
fi

# Set up output file path based on mode
if [ "$VERIFY_MODE" = "true" ]; then
    # In verify mode, OUTPUT_FILE is the existing checksum file
    CHECKSUM_FILE="$OUTPUT_FILE"
    
    # Handle relative path
    if [[ "$CHECKSUM_FILE" != /* ]]; then
        CHECKSUM_FILE="$(pwd)/${CHECKSUM_FILE}"
    fi
    
    if [ ! -f "$CHECKSUM_FILE" ]; then
        echo "[$(timestamp)] ERROR: Checksum file not found: $CHECKSUM_FILE"
        exit 1
    fi
    
    echo "[$(timestamp)] Mode: VERIFY"
    echo "[$(timestamp)] Checksum file: $CHECKSUM_FILE"
else
    # In generate mode, create output filename
    # Remove any existing path and extension from output name
    OUTPUT_BASE=$(basename "$OUTPUT_FILE" .txt)
    OUTPUT_BASE=$(echo "$OUTPUT_BASE" | sed 's/^md5sums-//')
    CHECKSUM_FILE="$(pwd)/md5sums-${OUTPUT_BASE}.txt"
    
    echo "[$(timestamp)] Mode: GENERATE"
    echo "[$(timestamp)] Output file: $CHECKSUM_FILE"
    
    # Check if output file exists
    if [ -f "$CHECKSUM_FILE" ]; then
        if [ "$APPEND_MODE" = "true" ]; then
            echo "[$(timestamp)] Append mode: will add to existing file"
        else
            echo "[$(timestamp)] WARNING: Output file already exists, will be overwritten"
        fi
    fi
fi

echo "[$(timestamp)] Recursive: $RECURSIVE"
echo "[$(timestamp)] Dry run: $DRY_RUN"

# Check if we have files to process
if [ -z "$FILE_PATTERN" ] && [ -z "$FILE_LIST" ] && [ -z "$SOURCE_DIR" ]; then
    if [ "$VERIFY_MODE" = "true" ]; then
        # In verify mode without source specification, verify all files in checksum file
        echo "[$(timestamp)] No file source specified, will verify all files in checksum file"
    else
        echo "[$(timestamp)] ERROR: At least one file source is required (-p, -f, or -s)"
        Help
        exit 1
    fi
fi

# Validate file list if provided
if [ -n "$FILE_LIST" ]; then
    if [ ! -f "$FILE_LIST" ]; then
        echo "[$(timestamp)] ERROR: File list not found: $FILE_LIST"
        exit 1
    fi
    echo "[$(timestamp)] File list: $FILE_LIST"
fi

# Validate and convert source directory if provided
if [ -n "$SOURCE_DIR" ]; then
    SOURCE_DIR=$(get_absolute_path "$SOURCE_DIR")
    
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "[$(timestamp)] ERROR: Source directory not found: $SOURCE_DIR"
        exit 1
    fi
    
    if [ "$RECURSIVE" = "false" ]; then
        echo "[$(timestamp)] WARNING: Source directory provided without -r flag"
        echo "[$(timestamp)]          Only files directly in $SOURCE_DIR will be processed"
    fi
    
    echo "[$(timestamp)] Source directory: $SOURCE_DIR"
fi

if [ -n "$FILE_PATTERN" ]; then
    echo "[$(timestamp)] File pattern: $FILE_PATTERN"
fi

#################### Build File List ####################

print_header "Building File List"

# Create temporary file to store all files to process
TEMP_FILE_LIST=$(mktemp)
trap "rm -f $TEMP_FILE_LIST" EXIT

# In verify mode with no source, extract files from checksum file
if [ "$VERIFY_MODE" = "true" ] && [ -z "$FILE_PATTERN" ] && [ -z "$FILE_LIST" ] && [ -z "$SOURCE_DIR" ]; then
    echo "[$(timestamp)] Extracting file list from checksum file..."
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Extract filename (second field, after hash and spaces)
        local_file=$(echo "$line" | awk '{print $2}')
        
        [ -z "$local_file" ] && continue
        
        # Convert to absolute path if needed
        if [[ "$local_file" != /* ]]; then
            local_file="$(pwd)/${local_file}"
        fi
        
        echo "$local_file" >> "$TEMP_FILE_LIST"
    done < "$CHECKSUM_FILE"
else
    # Build file list from provided sources
    
    # Process file pattern
    if [ -n "$FILE_PATTERN" ]; then
        echo "[$(timestamp)] Finding files matching pattern: $FILE_PATTERN"
        
        # Determine search directory
        local_search_dir="${SOURCE_DIR:-.}"
        
        if [ "$RECURSIVE" = "true" ]; then
            # Recursive search
            find "$local_search_dir" -type f -name "$FILE_PATTERN" 2>/dev/null | while IFS= read -r local_file; do
                echo "$local_file" >> "$TEMP_FILE_LIST"
            done
        else
            # Non-recursive - use glob in specified directory
            # shellcheck disable=SC2086
            for local_file in ${local_search_dir}/${FILE_PATTERN}; do
                if [ -f "$local_file" ]; then
                    local_abs_path=$(get_absolute_path "$local_file")
                    echo "$local_abs_path" >> "$TEMP_FILE_LIST"
                fi
            done
        fi
    fi
    
    # Process file list
    if [ -n "$FILE_LIST" ]; then
        echo "[$(timestamp)] Reading files from list: $FILE_LIST"
        
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            
            # Trim whitespace
            line=$(echo "$line" | xargs)
            
            # Convert to absolute path
            local_file=$(get_absolute_path "$line")
            
            echo "$local_file" >> "$TEMP_FILE_LIST"
        done < "$FILE_LIST"
    fi
    
    # Process source directory (if no pattern specified)
    if [ -n "$SOURCE_DIR" ] && [ -z "$FILE_PATTERN" ]; then
        echo "[$(timestamp)] Finding all files in: $SOURCE_DIR"
        
        if [ "$RECURSIVE" = "true" ]; then
            find "$SOURCE_DIR" -type f 2>/dev/null | while IFS= read -r local_file; do
                echo "$local_file" >> "$TEMP_FILE_LIST"
            done
        else
            # Non-recursive - only direct children
            find "$SOURCE_DIR" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r local_file; do
                echo "$local_file" >> "$TEMP_FILE_LIST"
            done
        fi
    fi
fi

# Remove duplicates and sort
if [ -f "$TEMP_FILE_LIST" ]; then
    sort -u "$TEMP_FILE_LIST" -o "$TEMP_FILE_LIST"
fi

# Count total files
TOTAL_FILES=$(wc -l < "$TEMP_FILE_LIST" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No files to process"
    exit 1
fi

echo "[$(timestamp)] Total files to process: $TOTAL_FILES"
echo

# Calculate total size
echo "[$(timestamp)] Calculating total data size..."
TOTAL_SIZE=0
while IFS= read -r local_file || [ -n "$local_file" ]; do
    if [ -f "$local_file" ]; then
        local_size=$(get_file_size "$local_file")
        TOTAL_SIZE=$((TOTAL_SIZE + local_size))
    fi
done < "$TEMP_FILE_LIST"
echo "[$(timestamp)] Total size: $(format_size $TOTAL_SIZE)"
echo

# Preview first few files
echo "[$(timestamp)] First 5 files to process:"
head -5 "$TEMP_FILE_LIST" | while IFS= read -r local_file; do
    local_size=$(format_size "$(get_file_size "$local_file")")
    echo "  - $local_file ($local_size)"
done
if [ "$TOTAL_FILES" -gt 5 ]; then
    echo "  ... and $((TOTAL_FILES - 5)) more files"
fi

#################### Load Checksum Data for Verify Mode ####################

# Create associative array for expected hashes (verify mode only)
declare -A EXPECTED_HASHES

if [ "$VERIFY_MODE" = "true" ]; then
    print_header "Loading Checksum Data"
    
    echo "[$(timestamp)] Reading expected checksums from: $CHECKSUM_FILE"
    
    HASH_COUNT=0
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Parse hash and filename
        local_hash=$(echo "$line" | awk '{print $1}')
        local_file=$(echo "$line" | awk '{print $2}')
        
        [ -z "$local_hash" ] || [ -z "$local_file" ] && continue
        
        # Convert to absolute path if needed
        if [[ "$local_file" != /* ]]; then
            local_file="$(pwd)/${local_file}"
        fi
        
        EXPECTED_HASHES["$local_file"]="$local_hash"
        HASH_COUNT=$((HASH_COUNT + 1))
    done < "$CHECKSUM_FILE"
    
    echo "[$(timestamp)] Loaded $HASH_COUNT checksums"
fi

#################### Process Files ####################

if [ "$VERIFY_MODE" = "true" ]; then
    print_header "Verifying Checksums"
else
    print_header "Generating Checksums"
fi

echo "[$(timestamp)] Starting processing..."
echo

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
RESULT_FILE=$(mktemp)
trap "rm -f $TEMP_FILE_LIST $SUCCESS_LOG $FAIL_LOG $RESULT_FILE" EXIT

# Record start time
JOB_START_TIME=$(date +%s)

# Process each file
while IFS= read -r source_file || [ -n "$source_file" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing file $CURRENT of $TOTAL_FILES"
    echo ""
    
    # Check if source file exists
    if [ ! -f "$source_file" ]; then
        echo "[$(timestamp)] SKIP: File not found: $source_file"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi
    
    # Process based on mode
    if [ "$VERIFY_MODE" = "true" ]; then
        # Verify mode
        expected_hash="${EXPECTED_HASHES[$source_file]:-}"
        
        if [ -z "$expected_hash" ]; then
            echo "[$(timestamp)] SKIP: No checksum found for: $source_file"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
        
        if verify_md5 "$source_file" "$expected_hash" "$DRY_RUN"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "$source_file" >> "$SUCCESS_LOG"
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "$source_file" >> "$FAIL_LOG"
        fi
    else
        # Generate mode
        md5_output=$(calculate_md5 "$source_file" "$DRY_RUN" | tail -1)
        
        if [ $? -eq 0 ] && [ -n "$md5_output" ]; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "$source_file" >> "$SUCCESS_LOG"
            
            # Save result
            if [ "$DRY_RUN" = "false" ]; then
                echo "$md5_output" >> "$RESULT_FILE"
            fi
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "$source_file" >> "$FAIL_LOG"
        fi
    fi
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_FILES"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT | Skipped: $SKIP_COUNT"
    
done < "$TEMP_FILE_LIST"

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Write Output File (Generate Mode) ####################

if [ "$VERIFY_MODE" = "false" ] && [ "$DRY_RUN" = "false" ]; then
    print_header "Writing Output"
    
    if [ "$APPEND_MODE" = "true" ] && [ -f "$CHECKSUM_FILE" ]; then
        echo "[$(timestamp)] Appending results to: $CHECKSUM_FILE"
        cat "$RESULT_FILE" >> "$CHECKSUM_FILE"
    else
        echo "[$(timestamp)] Writing results to: $CHECKSUM_FILE"
        
        # Add header comment
        {
            echo "# MD5 Checksums generated by md5Checker.sh"
            echo "# Date: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# Host: $(hostname)"
            echo "# Files: $SUCCESS_COUNT"
            echo "# Total size: $(format_size $TOTAL_SIZE)"
            echo "#"
            cat "$RESULT_FILE"
        } > "$CHECKSUM_FILE"
    fi
    
    echo "[$(timestamp)] Output file written successfully"
    echo "[$(timestamp)] File: $CHECKSUM_FILE"
    echo "[$(timestamp)] Lines: $(wc -l < "$CHECKSUM_FILE" | tr -d ' ')"
fi

#################### Summary ####################

print_header "Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Mode:                  $([ "$VERIFY_MODE" = "true" ] && echo "VERIFY" || echo "GENERATE")"
echo "  Total files processed: $TOTAL_FILES"
echo "  Successful:            $SUCCESS_COUNT"
echo "  Failed:                $FAIL_COUNT"
echo "  Skipped:               $SKIP_COUNT"
echo
echo "  Total data size:       $(format_size $TOTAL_SIZE)"
echo "  Total time:            $(format_duration $JOB_DURATION)"
echo "  Dry run:               $DRY_RUN"
echo

if [ "$VERIFY_MODE" = "false" ] && [ "$DRY_RUN" = "false" ]; then
    echo "  Output file:           $CHECKSUM_FILE"
    echo
fi

# Report failed files if any
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following files failed:"
    while IFS= read -r file; do
        echo "  - $file"
    done < "$FAIL_LOG"
    echo
fi

# Report skipped files if any
if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] INFO: $SKIP_COUNT files were skipped (not found or no checksum)"
fi

# Verification summary
if [ "$VERIFY_MODE" = "true" ]; then
    echo
    if [ "$FAIL_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -eq 0 ]; then
        echo "-------------------------------------------------------------"
        echo "  VERIFICATION PASSED: All $SUCCESS_COUNT files match!"
        echo "-------------------------------------------------------------"
    elif [ "$FAIL_COUNT" -eq 0 ]; then
        echo "-------------------------------------------------------------"
        echo "  VERIFICATION PASSED: $SUCCESS_COUNT files match"
        echo "  ($SKIP_COUNT files skipped)"
        echo "-------------------------------------------------------------"
    else
        echo "-------------------------------------------------------------"
        echo "  VERIFICATION FAILED: $FAIL_COUNT files do not match!"
        echo "-------------------------------------------------------------"
    fi
fi

# Exit with error if any files failed
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
else
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
fi

print_header "End of Job"