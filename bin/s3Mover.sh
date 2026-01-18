#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --time=18:00:00
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --output=log-s3Mover-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script copies files between local filesystem and S3, or within S3"
    echo "Source files are always preserved (copy mode only)"
    echo "It supports batch processing of multiple files via a text file input"
    echo
    echo "Supported Transfer Types:"
    echo "  - Local to S3 (upload)"
    echo "  - S3 to Local (download)"
    echo "  - S3 to S3 (copy within/across buckets)"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] ~/atelier/bin/s3Mover.sh -s [source] -d [dest] [options]'
    echo
    echo "Required Arguments:"
    echo "  -s [source]     Source path - can be:"
    echo "                    - S3 URI: s3://bucket/path/file or s3://bucket/path/"
    echo "                    - Local path: /path/to/file or /path/to/directory/"
    echo "                    - Relative path: ./path or path/to/file"
    echo "  -d [dest]       Destination path - can be:"
    echo "                    - S3 URI: s3://bucket/path/"
    echo "                    - Local path: /path/to/directory/"
    echo
    echo "Optional Arguments:"
    echo "  -f [fileList]   Text file containing list of file paths to copy (one per line)"
    echo "  -r              Recursive mode - copy all files in source directory"
    echo "  -n              Dry run - show what would be copied without actually doing it"
    echo "  -c [class]      S3 storage class for uploads (default: STANDARD)"
    echo "                    Options: STANDARD, GLACIER, DEEP_ARCHIVE"
    echo "  -h              Print this help message"
    echo
    echo "File List Format (for -f option):"
    echo "  - One path per line (S3 URI or local path)"
    echo "  - Relative paths will be prefixed with source path if provided"
    echo "  - Lines starting with # are treated as comments"
    echo "  - Empty lines are ignored"
    echo
    echo "Usage Examples:"
    echo
    echo "  # Upload a local file to S3"
    echo '  sbatch --job-name=upload ~/atelier/bin/s3Mover.sh -s /data/sample.bam -d s3://mybucket/data/'
    echo
    echo "  # Upload with GLACIER storage class"
    echo '  sbatch --job-name=archive ~/atelier/bin/s3Mover.sh -s /data/sample.bam -d s3://mybucket/archive/ -c GLACIER'
    echo
    echo "  # Upload directory recursively to DEEP_ARCHIVE (preserves directory name)"
    echo '  sbatch --job-name=deep-archive ~/atelier/bin/s3Mover.sh -s /data/project/ -d s3://mybucket/archive/ -r -c DEEP_ARCHIVE'
    echo '  # Result: s3://mybucket/archive/project/...'
    echo
    echo "  # Download from S3 to local"
    echo '  sbatch --job-name=download ~/atelier/bin/s3Mover.sh -s s3://mybucket/data/file.bam -d /local/data/'
    echo
    echo "  # Download S3 directory recursively"
    echo '  sbatch --job-name=download-dir ~/atelier/bin/s3Mover.sh -s s3://mybucket/data/project/ -d /local/data/ -r'
    echo
    echo "  # Copy files within S3"
    echo '  sbatch --job-name=s3copy ~/atelier/bin/s3Mover.sh -s s3://mybucket/data/file.bam -d s3://mybucket/archive/'
    echo
    echo "  # Copy files from a list"
    echo '  sbatch --job-name=batch ~/atelier/bin/s3Mover.sh -f files_to_copy.txt -d s3://mybucket/archive/'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=preview ~/atelier/bin/s3Mover.sh -s /data/project/ -d s3://mybucket/data/ -r -n'
    echo
    echo "Storage Class Information:"
    echo "  STANDARD      - Frequently accessed data, highest availability"
    echo "  GLACIER       - Archive data, retrieval in minutes to hours"
    echo "  DEEP_ARCHIVE  - Long-term archive, retrieval in 12-48 hours, lowest cost"
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

# Function to check if path is an S3 URI
is_s3_path() {
    local path="$1"
    if [[ "$path" == s3://* ]]; then
        return 0
    else
        return 1
    fi
}

# Function to convert local path to absolute path
get_absolute_path() {
    local input_path="$1"
    local abs_path=""
    
    # If it's an S3 path, return as-is
    if is_s3_path "$input_path"; then
        echo "$input_path"
        return 0
    fi
    
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

# Function to validate S3 path format
validate_s3_path() {
    local path="$1"
    if [[ ! "$path" =~ ^s3://[a-zA-Z0-9.-]+/.* ]]; then
        echo "[$(timestamp)] ERROR: Invalid S3 path format: $path"
        echo "[$(timestamp)] Expected format: s3://bucket-name/path/"
        return 1
    fi
    return 0
}

# Function to validate local path exists
validate_local_path() {
    local path="$1"
    local check_type="$2"  # "source" or "dest"
    
    if [ "$check_type" = "source" ]; then
        if [ ! -e "$path" ]; then
            echo "[$(timestamp)] ERROR: Local source path does not exist: $path"
            return 1
        fi
    fi
    return 0
}

# Function to validate storage class
validate_storage_class() {
    local storage_class="$1"
    case "$storage_class" in
        STANDARD|GLACIER|DEEP_ARCHIVE)
            return 0
            ;;
        *)
            echo "[$(timestamp)] ERROR: Invalid storage class: $storage_class"
            echo "[$(timestamp)] Valid options: STANDARD, GLACIER, DEEP_ARCHIVE"
            return 1
            ;;
    esac
}

# Function to check if S3 path exists
check_s3_exists() {
    local path="$1"
    if aws s3 ls "$path" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check if local path exists
check_local_exists() {
    local path="$1"
    if [ -e "$path" ]; then
        return 0
    else
        return 1
    fi
}

# Function to get file size (works for both local and S3)
get_file_size() {
    local path="$1"
    
    if is_s3_path "$path"; then
        local file_info
        file_info=$(aws s3 ls "$path" 2>/dev/null | head -1)
        echo "$file_info" | awk '{print $3}'
    else
        if [ -f "$path" ]; then
            # Try GNU stat first, then BSD stat
            stat --printf="%s" "$path" 2>/dev/null || stat -f%z "$path" 2>/dev/null || echo ""
        else
            echo ""
        fi
    fi
}

# Function to determine transfer type
get_transfer_type() {
    local source="$1"
    local dest="$2"
    
    local source_is_s3="false"
    local dest_is_s3="false"
    
    if is_s3_path "$source"; then
        source_is_s3="true"
    fi
    
    if is_s3_path "$dest"; then
        dest_is_s3="true"
    fi
    
    if [ "$source_is_s3" = "true" ] && [ "$dest_is_s3" = "true" ]; then
        echo "s3_to_s3"
    elif [ "$source_is_s3" = "true" ] && [ "$dest_is_s3" = "false" ]; then
        echo "s3_to_local"
    elif [ "$source_is_s3" = "false" ] && [ "$dest_is_s3" = "true" ]; then
        echo "local_to_s3"
    else
        echo "local_to_local"
    fi
}

# Function to copy a single file
copy_file() {
    local source_file="$1"
    local dest_file="$2"
    local dry_run="$3"
    local storage_class="$4"
    local transfer_type="$5"
    
    # Get file size for reporting
    local file_size
    file_size=$(get_file_size "$source_file")
    local formatted_size
    formatted_size=$(format_size "${file_size:-0}")
    
    # Build storage class option for S3 uploads
    local storage_class_opt=""
    if [ "$transfer_type" = "local_to_s3" ] || [ "$transfer_type" = "s3_to_s3" ]; then
        storage_class_opt="--storage-class ${storage_class}"
    fi
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would copy: $source_file -> $dest_file ($formatted_size)"
        if [ -n "$storage_class_opt" ]; then
            echo "[$(timestamp)] [DRY RUN] Storage class: $storage_class"
        fi
        return 0
    fi
    
    echo "[$(timestamp)] Copying: $source_file ($formatted_size)"
    echo "[$(timestamp)]      -> $dest_file"
    if [ "$transfer_type" = "local_to_s3" ] || [ "$transfer_type" = "s3_to_s3" ]; then
        echo "[$(timestamp)] Storage class: $storage_class"
    fi
    
    # Create destination directory for local destinations
    if ! is_s3_path "$dest_file"; then
        local dest_dir
        dest_dir=$(dirname "$dest_file")
        mkdir -p "$dest_dir"
    fi
    
    # Perform the copy based on transfer type
    local copy_success="false"
    
    case "$transfer_type" in
        s3_to_s3)
            if aws s3 cp "$source_file" "$dest_file" $storage_class_opt --only-show-errors; then
                echo "[$(timestamp)] SUCCESS: Copied $(basename "$source_file")"
                copy_success="true"
            fi
            ;;
        local_to_s3)
            if aws s3 cp "$source_file" "$dest_file" $storage_class_opt --only-show-errors; then
                echo "[$(timestamp)] SUCCESS: Uploaded $(basename "$source_file")"
                copy_success="true"
            fi
            ;;
        s3_to_local)
            if aws s3 cp "$source_file" "$dest_file" --only-show-errors; then
                echo "[$(timestamp)] SUCCESS: Downloaded $(basename "$source_file")"
                copy_success="true"
            fi
            ;;
        local_to_local)
            if cp "$source_file" "$dest_file"; then
                echo "[$(timestamp)] SUCCESS: Copied $(basename "$source_file")"
                copy_success="true"
            fi
            ;;
    esac
    
    if [ "$copy_success" = "true" ]; then
        return 0
    else
        echo "[$(timestamp)] FAILED: Could not copy $(basename "$source_file")"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
SOURCE_PATH=""
DEST_PATH=""
FILE_LIST=""
RECURSIVE="false"
DRY_RUN="false"
STORAGE_CLASS="STANDARD"

# Parse command line options
while getopts ":hs:d:f:c:rn" option; do
    case $option in
        h) # Show help message
            Help
            exit 0
            ;;
        s) # Source path
            SOURCE_PATH="$OPTARG"
            ;;
        d) # Destination path
            DEST_PATH="$OPTARG"
            ;;
        f) # File list
            FILE_LIST="$OPTARG"
            ;;
        c) # Storage class
            STORAGE_CLASS="$OPTARG"
            ;;
        r) # Recursive mode
            RECURSIVE="true"
            ;;
        n) # Dry run
            DRY_RUN="true"
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

print_header "S3 File Copier"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"

#################### Validate Inputs ####################

print_header "Input Validation"

# Check if destination is provided
if [ -z "$DEST_PATH" ]; then
    echo "[$(timestamp)] ERROR: Destination path (-d) is required"
    Help
    exit 1
fi

# Validate storage class
if ! validate_storage_class "$STORAGE_CLASS"; then
    exit 1
fi

# Process destination path
echo "[$(timestamp)] Original destination: $DEST_PATH"

if is_s3_path "$DEST_PATH"; then
    if ! validate_s3_path "$DEST_PATH"; then
        exit 1
    fi
    # Ensure S3 destination ends with /
    DEST_PATH="${DEST_PATH%/}/"
    DEST_TYPE="S3"
else
    # Local destination - convert to absolute path
    DEST_PATH=$(get_absolute_path "$DEST_PATH")
    DEST_PATH="${DEST_PATH%/}/"
    DEST_TYPE="Local"
fi

echo "[$(timestamp)] Resolved destination: $DEST_PATH ($DEST_TYPE)"
echo "[$(timestamp)] Storage Class: $STORAGE_CLASS"
echo "[$(timestamp)] Recursive: $RECURSIVE"
echo "[$(timestamp)] Dry run: $DRY_RUN"

# Check if we have source files to process
if [ -z "$SOURCE_PATH" ] && [ -z "$FILE_LIST" ]; then
    echo "[$(timestamp)] ERROR: Either source path (-s) or file list (-f) is required"
    Help
    exit 1
fi

# If file list provided, check it exists
if [ -n "$FILE_LIST" ]; then
    if [ ! -f "$FILE_LIST" ]; then
        echo "[$(timestamp)] ERROR: File list not found: $FILE_LIST"
        exit 1
    fi
    echo "[$(timestamp)] File list: $FILE_LIST"
fi

# Store the original source directory name for recursive operations
SOURCE_DIR_NAME=""

# If source path provided, validate and convert it
if [ -n "$SOURCE_PATH" ]; then
    echo "[$(timestamp)] Original source: $SOURCE_PATH"
    
    if is_s3_path "$SOURCE_PATH"; then
        if ! validate_s3_path "$SOURCE_PATH"; then
            exit 1
        fi
        SOURCE_TYPE="S3"
        
        # Extract the directory name from S3 path for recursive operations
        SOURCE_DIR_NAME=$(basename "${SOURCE_PATH%/}")
        
        # Check if source exists
        if ! check_s3_exists "$SOURCE_PATH"; then
            echo "[$(timestamp)] WARNING: Source path may not exist or may be empty: $SOURCE_PATH"
        fi
    else
        # Local source - convert to absolute path
        SOURCE_PATH=$(get_absolute_path "$SOURCE_PATH")
        SOURCE_TYPE="Local"
        
        # Extract the directory name for recursive operations
        SOURCE_DIR_NAME=$(basename "${SOURCE_PATH%/}")
        
        if ! validate_local_path "$SOURCE_PATH" "source"; then
            exit 1
        fi
        
        # Check if source is a directory without -r flag
        if [ -d "$SOURCE_PATH" ] && [ "$RECURSIVE" = "false" ]; then
            echo "[$(timestamp)] ERROR: Source is a directory. Use -r for recursive mode."
            exit 1
        fi
    fi
    
    echo "[$(timestamp)] Resolved source: $SOURCE_PATH ($SOURCE_TYPE)"
    echo "[$(timestamp)] Source directory name: $SOURCE_DIR_NAME"
fi

# Determine and display transfer type
if [ -n "$SOURCE_PATH" ]; then
    TRANSFER_TYPE=$(get_transfer_type "$SOURCE_PATH" "$DEST_PATH")
    echo "[$(timestamp)] Transfer type: $TRANSFER_TYPE"
fi

#################### Load AWS CLI ####################

print_header "Environment Setup"

# Determine if we need AWS CLI
NEED_AWS="false"
if is_s3_path "$DEST_PATH"; then
    NEED_AWS="true"
fi
if [ -n "$SOURCE_PATH" ] && is_s3_path "$SOURCE_PATH"; then
    NEED_AWS="true"
fi
if [ -n "$FILE_LIST" ]; then
    # Might have S3 paths in file list, so load AWS CLI to be safe
    NEED_AWS="true"
fi

if [ "$NEED_AWS" = "true" ]; then
    # Try to load AWS CLI module (common on HPC systems)
    if command -v module &> /dev/null; then
        echo "[$(timestamp)] Loading AWS CLI module..."
        module load aws-cli 2>/dev/null || module load awscli 2>/dev/null || echo "[$(timestamp)] No AWS CLI module found, using system AWS CLI"
        module list -t 2>&1 || true
    fi
    
    # Verify AWS CLI is available
    if ! command -v aws &> /dev/null; then
        echo "[$(timestamp)] ERROR: AWS CLI is not installed or not in PATH"
        exit 1
    fi
    
    echo "[$(timestamp)] AWS CLI version: $(aws --version)"
    echo
    
    # Test AWS credentials
    echo "[$(timestamp)] Testing AWS credentials..."
    if aws sts get-caller-identity &>/dev/null; then
        echo "[$(timestamp)] AWS credentials validated successfully"
        aws sts get-caller-identity --output table 2>/dev/null || true
    else
        echo "[$(timestamp)] ERROR: AWS credentials not configured or invalid"
        exit 1
    fi
else
    echo "[$(timestamp)] Local-only transfer, AWS CLI not required"
fi

#################### Build File List ####################

print_header "Building File List"

# Create temporary file to store all files to process
# Format: source_file|destination_file
TEMP_FILE_LIST=$(mktemp)
trap "rm -f $TEMP_FILE_LIST" EXIT

# If file list provided, process it
if [ -n "$FILE_LIST" ]; then
    echo "[$(timestamp)] Reading files from: $FILE_LIST"
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        line=$(echo "$line" | xargs)
        
        # Determine the full source path
        local_source=""
        if is_s3_path "$line"; then
            local_source="$line"
        elif [[ "$line" == /* ]]; then
            # Absolute local path
            local_source="$line"
        else
            # Relative path - prepend source path or current directory
            if [ -n "$SOURCE_PATH" ] && ! is_s3_path "$SOURCE_PATH"; then
                local_source="${SOURCE_PATH%/}/${line}"
            else
                local_source="$(pwd)/${line}"
            fi
        fi
        
        # Determine destination
        local_dest="${DEST_PATH}$(basename "$local_source")"
        
        echo "${local_source}|${local_dest}" >> "$TEMP_FILE_LIST"
    done < "$FILE_LIST"
fi

# If source path provided and no file list
if [ -n "$SOURCE_PATH" ] && [ -z "$FILE_LIST" ]; then
    if [ "$RECURSIVE" = "true" ]; then
        echo "[$(timestamp)] Listing files recursively from: $SOURCE_PATH"
        
        if is_s3_path "$SOURCE_PATH"; then
            # S3 recursive listing
            local_source_prefix="${SOURCE_PATH%/}/"
            
            # Get bucket name
            local_bucket=$(echo "$SOURCE_PATH" | sed 's|s3://||' | cut -d'/' -f1)
            
            # Get the prefix within the bucket
            local_s3_prefix=$(echo "$SOURCE_PATH" | sed "s|s3://${local_bucket}/||" | sed 's|/$||')
            
            aws s3 ls "$local_source_prefix" --recursive 2>/dev/null | while IFS= read -r line; do
                # Skip empty lines
                [ -z "$line" ] && continue
                
                # Extract the size (third field) and file path
                local_file_size=$(echo "$line" | awk '{print $3}')
                local_file_key=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
                
                # Skip if size is 0 (this is a directory marker) or file_key ends with /
                if [ "$local_file_size" -eq 0 ] || [[ "$local_file_key" == */ ]]; then
                    continue
                fi
                
                [ -z "$local_file_key" ] && continue
                
                # Full S3 URI for source
                local_source_file="s3://${local_bucket}/${local_file_key}"
                
                # Calculate relative path from the source prefix
                local_relative_path="${local_file_key#${local_s3_prefix}/}"
                
                # Build destination
                local_dest_file="${DEST_PATH}${SOURCE_DIR_NAME}/${local_relative_path}"
                
                echo "${local_source_file}|${local_dest_file}" >> "$TEMP_FILE_LIST"
            done
        else
            # Local recursive listing
            local_source_base="${SOURCE_PATH%/}"
            
            find "$local_source_base" -type f | while IFS= read -r local_file; do
                # Calculate relative path from source directory
                local_relative_path="${local_file#${local_source_base}/}"
                
                # Build destination
                local_dest_file="${DEST_PATH}${SOURCE_DIR_NAME}/${local_relative_path}"
                
                echo "${local_file}|${local_dest_file}" >> "$TEMP_FILE_LIST"
            done
        fi
    else
        # Single file mode
        local_source="$SOURCE_PATH"
        local_dest="${DEST_PATH}$(basename "$SOURCE_PATH")"
        echo "${local_source}|${local_dest}" >> "$TEMP_FILE_LIST"
    fi
fi

# Count total files
TOTAL_FILES=$(wc -l < "$TEMP_FILE_LIST" | tr -d ' ')

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "[$(timestamp)] ERROR: No files to process"
    exit 1
fi

echo "[$(timestamp)] Total files to process: $TOTAL_FILES"
echo

# Preview first few files
echo "[$(timestamp)] First 5 files to process:"
head -5 "$TEMP_FILE_LIST" | while IFS='|' read -r src dst; do
    echo "  - $src"
    echo "    -> $dst"
done
if [ "$TOTAL_FILES" -gt 5 ]; then
    echo "  ... and $((TOTAL_FILES - 5)) more files"
fi

#################### Process Files ####################

print_header "Processing Files"

echo "[$(timestamp)] Starting file copy..."
echo

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CURRENT=0

# Create log files for tracking
SUCCESS_LOG=$(mktemp)
FAIL_LOG=$(mktemp)
trap "rm -f $TEMP_FILE_LIST $SUCCESS_LOG $FAIL_LOG" EXIT

# Process each file
while IFS='|' read -r source_file dest_file || [ -n "$source_file" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing file $CURRENT of $TOTAL_FILES"
    echo ""
    
    # Determine transfer type for this file
    file_transfer_type=$(get_transfer_type "$source_file" "$dest_file")
    
    # Check if source file exists
    if is_s3_path "$source_file"; then
        if ! check_s3_exists "$source_file"; then
            echo "[$(timestamp)] SKIP: Source file not found: $source_file"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
    else
        if ! check_local_exists "$source_file"; then
            echo "[$(timestamp)] SKIP: Source file not found: $source_file"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            continue
        fi
    fi
    
    # Copy the file
    if copy_file "$source_file" "$dest_file" "$DRY_RUN" "$STORAGE_CLASS" "$file_transfer_type"; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "$source_file" >> "$SUCCESS_LOG"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$source_file" >> "$FAIL_LOG"
    fi
    
    # Print progress summary
    echo
    print_progress "$CURRENT" "$TOTAL_FILES"
    echo
    echo "[$(timestamp)] Running totals - Success: $SUCCESS_COUNT | Failed: $FAIL_COUNT | Skipped: $SKIP_COUNT"
    
done < "$TEMP_FILE_LIST"

#################### Summary ####################

print_header "Copy Summary"

echo "[$(timestamp)] Job completed"
echo
echo "------------------  FINAL RESULTS  -------------------------"
echo
echo "  Total files processed: $TOTAL_FILES"
echo "  Successful:            $SUCCESS_COUNT"
echo "  Failed:                $FAIL_COUNT"
echo "  Skipped:               $SKIP_COUNT"
echo
echo "  Source:                ${SOURCE_PATH:-"(from file list)"}"
echo "  Destination:           $DEST_PATH"
echo "  Storage Class:         $STORAGE_CLASS"
echo "  Dry run:               $DRY_RUN"
echo

# Report failed files if any
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following files failed to copy:"
    while IFS= read -r file; do
        echo "  - $file"
    done < "$FAIL_LOG"
    echo
fi

# Exit with error if any files failed
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] Job completed with errors"
    exit 1
else
    echo "[$(timestamp)] Job completed successfully"
    exit 0
fi

print_header "End of Job"
