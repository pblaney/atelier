#!/bin/bash

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script renames files based on a mapping file"
    echo "Supports batch renaming with dry-run capability"
    echo
    echo "Features:"
    echo "  - Rename single file or batch rename multiple files"
    echo "  - Dry-run mode to preview changes without executing"
    echo "  - Detailed logging of all rename operations"
    echo "  - Error handling and validation"
    echo
    echo "Usage:"
    echo '  fileRenamer.sh -f [mappingFile] [options]'
    echo
    echo "Required Arguments:"
    echo "  -f [mappingFile]  Text file with old and new filenames"
    echo "                    Format: old_name<TAB>new_name (one per line)"
    echo
    echo "Optional Arguments:"
    echo "  -d [sourceDir]    Source directory for files (default: current directory)"
    echo "  -n                Dry run - show what would be renamed without executing"
    echo "  -v                Verbose output with additional details"
    echo "  -h                Print this help message"
    echo
    echo "Mapping File Format:"
    echo "  - Tab-separated old and new filenames"
    echo "  - One mapping per line"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo "  - WARNING: Be careful with special characters in filenames"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Basic rename from mapping file"
    echo '  fileRenamer.sh -f rename_list.txt'
    echo
    echo "  # Dry run to preview changes"
    echo '  fileRenamer.sh -f rename_list.txt -n'
    echo
    echo "  # Rename files in specific directory"
    echo '  fileRenamer.sh -f rename_list.txt -d /data/samples/'
    echo
    echo "  # Verbose output with detailed logging"
    echo '  fileRenamer.sh -f rename_list.txt -v'
    echo
    echo "  # Combine options"
    echo '  fileRenamer.sh -f rename_list.txt -d /data/samples/ -n -v'
    echo
    echo "Mapping File Examples:"
    echo "  # Basic example"
    echo "  sample_001.bam	sample_A.bam"
    echo "  sample_002.bam	sample_B.bam"
    echo "  sample_003.bam	sample_C.bam"
    echo
    echo "  # With comments"
    echo "  # Batch 1 samples"
    echo "  old_sample_1.fastq	new_sample_1.fastq"
    echo "  old_sample_2.fastq	new_sample_2.fastq"
    echo
    echo "Output:"
    echo "  - Log file: renamedFiles.log (created in current directory)"
    echo "  - Detailed success/failure information for each rename"
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

# Function to rename a single file
rename_file() {
    local source_dir="$1"
    local old_name="$2"
    local new_name="$3"
    local dry_run="$4"
    local verbose="$5"
    
    local old_path="${source_dir}/${old_name}"
    local new_path="${source_dir}/${new_name}"
    
    # Check if old file exists
    if [ ! -e "$old_path" ]; then
        echo "[$(timestamp)] SKIP: Source file not found: $old_name"
        return 2
    fi
    
    # Check if new name already exists
    if [ -e "$new_path" ]; then
        echo "[$(timestamp)] ERROR: Destination file already exists: $new_name"
        return 1
    fi
    
    # Get file size
    local file_size
    file_size=$(stat --printf="%s" "$old_path" 2>/dev/null || stat -f%z "$old_path" 2>/dev/null || echo "0")
    local formatted_size
    formatted_size=$(format_size "$file_size")
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would rename: $old_name -> $new_name"
        if [ "$verbose" = "true" ]; then
            echo "[$(timestamp)] [DRY RUN]   Size: $formatted_size"
        fi
        return 0
    fi
    
    echo "[$(timestamp)] Renaming: $old_name -> $new_name"
    if [ "$verbose" = "true" ]; then
        echo "[$(timestamp)]   Size: $formatted_size"
    fi
    
    # Perform rename
    if mv "$old_path" "$new_path"; then
        echo "[$(timestamp)] SUCCESS: Renamed $old_name"
        return 0
    else
        echo "[$(timestamp)] FAILED: Could not rename $old_name"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
MAPPING_FILE=""
SOURCE_DIR=""
DRY_RUN="false"
VERBOSE="false"

# Parse command line options
while getopts ":hf:d:nv" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        f) # Mapping file
            MAPPING_FILE="$OPTARG"
            ;;
        d) # Source directory
            SOURCE_DIR="$OPTARG"
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

print_header "File Renamer"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Working directory: $(pwd)"

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if mapping file is provided
if [ -z "$MAPPING_FILE" ]; then
    echo "[$(timestamp)] ERROR: Mapping file (-f) is required"
    Help
    exit 1
fi

# Check if mapping file exists
if [ ! -f "$MAPPING_FILE" ]; then
    echo "[$(timestamp)] ERROR: Mapping file not found: $MAPPING_FILE"
    exit 1
fi

MAPPING_FILE=$(get_absolute_path "$MAPPING_FILE")
echo "[$(timestamp)] Mapping file: $MAPPING_FILE"

# Set up source directory
if [ -z "$SOURCE_DIR" ]; then
    SOURCE_DIR="$(pwd)"
    echo "[$(timestamp)] Source directory not specified, using current directory"
else
    SOURCE_DIR=$(get_absolute_path "$SOURCE_DIR")
    if [ ! -d "$SOURCE_DIR" ]; then
        echo "[$(timestamp)] ERROR: Source directory not found: $SOURCE_DIR"
        exit 1
    fi
fi

echo "[$(timestamp)] Source directory: $SOURCE_DIR"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Verbose output: $VERBOSE"

#################### Build Rename List ####################

print_header "Building Rename List"

# Create temporary file to store rename operations
TEMP_RENAME_LIST=$(mktemp)
trap "rm -f $TEMP_RENAME_LIST" EXIT

echo "[$(timestamp)] Reading mapping file..."

VALID_COUNT=0
INVALID_COUNT=0
COMMENT_COUNT=0

while IFS=$'\t' read -r old_name new_name || [ -n "$old_name" ]; do
    # Skip empty lines
    [[ -z "$old_name" ]] && continue
    
    # Skip comments
    if [[ "$old_name" =~ ^[[:space:]]*# ]]; then
        COMMENT_COUNT=$((COMMENT_COUNT + 1))
        continue
    fi
    
    # Trim whitespace
    old_name=$(echo "$old_name" | xargs)
    new_name=$(echo "$new_name" | xargs)
    
    # Validate we have both old and new names
    if [ -z "$old_name" ] || [ -z "$new_name" ]; then
        echo "[$(timestamp)] WARNING: Skipping line with missing old or new name"
        INVALID_COUNT=$((INVALID_COUNT + 1))
        continue
    fi
    
    # Check for problematic characters
    if [[ "$new_name" =~ [\"\'\\] ]]; then
        echo "[$(timestamp)] WARNING: New filename contains special characters: $new_name"
    fi
    
    echo "${old_name}|${new_name}" >> "$TEMP_RENAME_LIST"
    VALID_COUNT=$((VALID_COUNT + 1))
    
done < "$MAPPING_FILE"

# Count total rename operations
TOTAL_RENAMES=$(wc -l < "$TEMP_RENAME_LIST" 2>/dev/null | tr -d ' ' || echo "0")

if [ "$TOTAL_RENAMES" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No valid rename mappings found"
    exit 1
fi

echo "[$(timestamp)] Valid mappings: $VALID_COUNT"
if [ "$COMMENT_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Comments skipped: $COMMENT_COUNT"
fi
if [ "$INVALID_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Invalid lines skipped: $INVALID_COUNT"
fi

echo "[$(timestamp)] Total rename operations to perform: $TOTAL_RENAMES"
echo

# Preview rename operations based on total count
if [ "$TOTAL_RENAMES" -eq 1 ]; then
    echo "[$(timestamp)] Rename operation to perform:"
    cat "$TEMP_RENAME_LIST" | while IFS='|' read -r old_name new_name; do
        if [ -e "${SOURCE_DIR}/${old_name}" ]; then
            local_size=$(format_size "$(stat --printf="%s" "${SOURCE_DIR}/${old_name}" 2>/dev/null || stat -f%z "${SOURCE_DIR}/${old_name}" 2>/dev/null || echo "0")")
            echo "  - $old_name ($local_size) → $new_name"
        else
            echo "  - $old_name (not found) → $new_name"
        fi
    done
elif [ "$TOTAL_RENAMES" -le 5 ]; then
    echo "[$(timestamp)] All $TOTAL_RENAMES rename operations to perform:"
    cat "$TEMP_RENAME_LIST" | while IFS='|' read -r old_name new_name; do
        if [ -e "${SOURCE_DIR}/${old_name}" ]; then
            local_size=$(format_size "$(stat --printf="%s" "${SOURCE_DIR}/${old_name}" 2>/dev/null || stat -f%z "${SOURCE_DIR}/${old_name}" 2>/dev/null || echo "0")")
            echo "  - $old_name ($local_size) → $new_name"
        else
            echo "  - $old_name (not found) → $new_name"
        fi
    done
else
    echo "[$(timestamp)] First 5 of $TOTAL_RENAMES rename operations to perform:"
    head -5 "$TEMP_RENAME_LIST" | while IFS='|' read -r old_name new_name; do
        if [ -e "${SOURCE_DIR}/${old_name}" ]; then
            local_size=$(format_size "$(stat --printf="%s" "${SOURCE_DIR}/${old_name}" 2>/dev/null || stat -f%z "${SOURCE_DIR}/${old_name}" 2>/dev/null || echo "0")")
            echo "  - $old_name ($local_size) → $new_name"
        else
            echo "  - $old_name (not found) → $new_name"
        fi
    done
    echo "  ... and $((TOTAL_RENAMES - 5)) more operations"
fi

#################### Perform Renames ####################

print_header "Performing Renames"

echo "[$(timestamp)] Starting file rename operations..."

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
SKIP_LOG=$(mktemp)
trap "rm -f $TEMP_RENAME_LIST $SUCCESS_LOG $FAIL_LOG $SKIP_LOG" EXIT

# Record start time
JOB_START_TIME=$(date +%s)

# Process each rename operation
while IFS='|' read -r old_name new_name || [ -n "$old_name" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing rename $CURRENT of $TOTAL_RENAMES"
    echo ""
    
    # Rename the file
    rename_file "$SOURCE_DIR" "$old_name" "$new_name" "$DRY_RUN" "$VERBOSE"
    rename_result=$?
    
    case $rename_result in
        0)
            # Success
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            echo "${old_name}|${new_name}" >> "$SUCCESS_LOG"
            ;;
        1)
            # Failed
            FAIL_COUNT=$((FAIL_COUNT + 1))
            echo "${old_name}|${new_name}" >> "$FAIL_LOG"
            ;;
        2)
            # Skipped (file not found)
            SKIP_COUNT=$((SKIP_COUNT + 1))
            echo "${old_name}|${new_name}" >> "$SKIP_LOG"
            ;;
    esac
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_RENAMES"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT | Skipped: $SKIP_COUNT"
    
done < "$TEMP_RENAME_LIST"

# Record end time
JOB_END_TIME=$(date +%s)
JOB_DURATION=$((JOB_END_TIME - JOB_START_TIME))

#################### Summary ####################

print_header "Rename Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total rename operations: $TOTAL_RENAMES"
echo "  Successful:              $SUCCESS_COUNT"
echo "  Failed:                  $FAIL_COUNT"
echo "  Skipped (not found):     $SKIP_COUNT"
echo
echo "  Source directory:        $SOURCE_DIR"
echo "  Dry run:                 $DRY_RUN"
echo "  Verbose output:          $VERBOSE"
echo "  Total time:              $(format_duration $JOB_DURATION)"
echo

# Report successful renames
if [ "$SUCCESS_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Successfully renamed:"
    while IFS='|' read -r old_name new_name; do
        echo "  ✓ $old_name → $new_name"
    done < "$SUCCESS_LOG" | head -5
    if [ "$SUCCESS_COUNT" -gt 5 ]; then
        echo "  ... and $((SUCCESS_COUNT - 5)) more"
    fi
    echo
fi

# Report skipped files
if [ "$SKIP_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Skipped (files not found):"
    while IFS='|' read -r old_name new_name; do
        echo "  ⊘ $old_name"
    done < "$SKIP_LOG" | head -5
    if [ "$SKIP_COUNT" -gt 5 ]; then
        echo "  ... and $((SKIP_COUNT - 5)) more"
    fi
    echo
fi

# Report failed renames
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following renames failed:"
    while IFS='|' read -r old_name new_name; do
        echo "  ✗ $old_name → $new_name"
    done < "$FAIL_LOG"
    echo
fi

# Create log file
LOG_FILE="renamedFiles.log"
{
    echo "File Rename Summary"
    echo "===================="
    echo "Timestamp: $(timestamp)"
    echo "Mapping file: $MAPPING_FILE"
    echo "Source directory: $SOURCE_DIR"
    echo "Dry run: $DRY_RUN"
    echo ""
    echo "Results:"
    echo "--------"
    echo "Total operations: $TOTAL_RENAMES"
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: $FAIL_COUNT"
    echo "Skipped: $SKIP_COUNT"
    echo "Total time: $(format_duration $JOB_DURATION)"
    echo ""
    
    if [ "$SUCCESS_COUNT" -gt 0 ]; then
        echo "Successfully Renamed:"
        echo "-------------------"
        while IFS='|' read -r old_name new_name; do
            echo "  $old_name → $new_name"
        done < "$SUCCESS_LOG"
        echo ""
    fi
    
    if [ "$SKIP_COUNT" -gt 0 ]; then
        echo "Skipped (Not Found):"
        echo "-------------------"
        while IFS='|' read -r old_name new_name; do
            echo "  $old_name → $new_name"
        done < "$SKIP_LOG"
        echo ""
    fi
    
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "Failed Renames:"
        echo "---------------"
        while IFS='|' read -r old_name new_name; do
            echo "  $old_name → $new_name"
        done < "$FAIL_LOG"
    fi
} > "$LOG_FILE"

echo "[$(timestamp)] Log file created: $LOG_FILE"
echo

# Success summary
if [ "$FAIL_COUNT" -eq 0 ] && [ "$DRY_RUN" = "false" ]; then
    echo "-------------------------------------------------------------"
    echo "  SUCCESS: All $SUCCESS_COUNT files renamed successfully!"
    echo
    echo "[$(timestamp)] Job completed successfully"
    exit 0
elif [ "$DRY_RUN" = "true" ]; then
    echo "-------------------------------------------------------------"
    echo "  DRY RUN COMPLETE: Ready to rename $SUCCESS_COUNT files"
    echo
    echo "[$(timestamp)] Dry run completed - no files were actually renamed"
    exit 0
else
    echo "-------------------------------------------------------------"
    echo "  PARTIAL SUCCESS: $SUCCESS_COUNT renamed, $FAIL_COUNT failed"
    echo
    echo "[$(timestamp)] Job completed with errors"
    exit 1
fi

print_header "End of Job"