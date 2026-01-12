#!/bin/bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=4G
#SBATCH --time=18:00:00
#SBATCH --mail-user=patrick.blaney@nyulangone.org
#SBATCH --mail-type=BEGIN,FAIL,END
#SBATCH --output=log-s3Mover-%x.out

#################### Help Message ####################
Help()
{
    # Display help message
    echo "This script moves/copies files between local filesystem and S3, or within S3"
    echo "It supports batch processing of multiple files via a text file input"
    echo
    echo "Supported Transfer Types:"
    echo "  - Local to S3 (upload)"
    echo "  - S3 to Local (download)"
    echo "  - S3 to S3 (transfer within/across buckets)"
    echo
    echo "Usage:"
    echo '  sbatch --job-name=[jobName] s3Mover.sh -s [source] -d [dest] [options]'
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
    echo "  -f [fileList]   Text file containing list of file paths to transfer (one per line)"
    echo "  -r              Recursive mode - transfer all files in source directory"
    echo "  -n              Dry run - show what would be transferred without actually doing it"
    echo "  -k              Keep source files (copy instead of move)"
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
    echo '  sbatch --job-name=upload s3Mover.sh -s /data/sample.bam -d s3://mybucket/data/'
    echo
    echo "  # Upload with GLACIER storage class"
    echo '  sbatch --job-name=archive s3Mover.sh -s /data/sample.bam -d s3://mybucket/archive/ -c GLACIER'
    echo
    echo "  # Upload directory recursively to DEEP_ARCHIVE"
    echo '  sbatch --job-name=deep-archive s3Mover.sh -s /data/project/ -d s3://mybucket/archive/ -r -c DEEP_ARCHIVE'
    echo
    echo "  # Download from S3 to local"
    echo '  sbatch --job-name=download s3Mover.sh -s s3://mybucket/data/file.bam -d /local/data/'
    echo
    echo "  # Download S3 directory recursively"
    echo '  sbatch --job-name=download-dir s3Mover.sh -s s3://mybucket/data/project/ -d /local/data/project/ -r'
    echo
    echo "  # Move files within S3"
    echo '  sbatch --job-name=s3move s3Mover.sh -s s3://mybucket/data/file.bam -d s3://mybucket/archive/'
    echo
    echo "  # Transfer files from a list (mixed local/S3 sources)"
    echo '  sbatch --job-name=batch s3Mover.sh -f files_to_transfer.txt -d s3://mybucket/archive/'
    echo
    echo "  # Dry run to preview operations"
    echo '  sbatch --job-name=preview s3Mover.sh -s /data/project/ -d s3://mybucket/data/ -r -n'
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
    [[ "$path" =~ ^s3:// ]]
}

# Function to convert local path to absolute path
# This handles relative paths, ./, ../, and already absolute paths
get_absolute_path() {
    local path="$1"
    
    # If it's an S3 path, return as-is
    if is_s3_path "$path"; then
        echo "$path"
        return
    fi
    
    # Check if path exists
    if [ -e "$path" ]; then
        # For existing paths, use realpath or fallback method
        if command -v realpath &> /dev/null; then
            realpath "$path"
        else
            # Fallback for systems without realpath
            if [ -d "$path" ]; then
                echo "$(cd "$path" && pwd)"
            else
                local dir
                local base
                dir=$(dirname "$path")
                base=$(basename "$path")
                echo "$(cd "$dir" && pwd)/${base}"
            fi
        fi
    else
        # Path doesn't exist yet (might be destination)
        # Try to resolve parent directory
        local dir
        local base
        dir=$(dirname "$path")
        base=$(basename "$path")
        
        if [ -d "$dir" ]; then
            if command -v realpath &> /dev/null; then
                echo "$(realpath "$dir")/${base}"
            else
                echo "$(cd "$dir" && pwd)/${base}"
            fi
        else
            # Parent doesn't exist either, just prepend PWD for relative paths
            if [[ "$path" =~ ^/ ]]; then
                echo "$path"
            else
                echo "$(pwd)/${path}"
            fi
        fi
    fi
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
    elif [ "$check_type" = "dest" ]; then
        # For destination, check if parent directory exists or can be created
        local parent_dir=$(dirname "$path")
        if [ ! -d "$parent_dir" ]; then
            echo "[$(timestamp)] INFO: Parent directory does not exist, will attempt to create: $parent_dir"
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
    [ -e "$path" ]
}

# Function to get file size (works for both local and S3)
get_file_size() {
    local path="$1"
    
    if is_s3_path "$path"; then
        local file_info=$(aws s3 ls "$path" 2>/dev/null | head -1)
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
    
    local source_is_s3=$(is_s3_path "$source" && echo "true" || echo "false")
    local dest_is_s3=$(is_s3_path "$dest" && echo "true" || echo "false")
    
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

# Function to transfer a single file
transfer_file() {
    local source_file="$1"
    local dest_path="$2"
    local keep_source="$3"
    local dry_run="$4"
    local storage_class="$5"
    local transfer_type="$6"
    
    # Extract filename from source
    local filename=$(basename "$source_file")
    
    # Determine full destination path
    local dest_file
    if is_s3_path "$dest_path"; then
        dest_file="${dest_path%/}/${filename}"
    else
        # Local destination
        dest_file="${dest_path%/}/${filename}"
    fi
    
    # Get file size for reporting
    local file_size=$(get_file_size "$source_file")
    local formatted_size=$(format_size "${file_size:-0}")
    
    # Build storage class option for S3 uploads
    local storage_class_opt=""
    if [ "$transfer_type" = "local_to_s3" ] || [ "$transfer_type" = "s3_to_s3" ]; then
        storage_class_opt="--storage-class $storage_class"
    fi
    
    if [ "$dry_run" = "true" ]; then
        echo "[$(timestamp)] [DRY RUN] Would transfer: $source_file -> $dest_file ($formatted_size)"
        if [ -n "$storage_class_opt" ]; then
            echo "[$(timestamp)] [DRY RUN] Storage class: $storage_class"
        fi
        return 0
    fi
    
    echo "[$(timestamp)] Transferring: $source_file ($formatted_size)"
    echo "[$(timestamp)]          -> $dest_file"
    if [ "$transfer_type" = "local_to_s3" ] || [ "$transfer_type" = "s3_to_s3" ]; then
        echo "[$(timestamp)] Storage class: $storage_class"
    fi
    
    # Create destination directory for local destinations
    if ! is_s3_path "$dest_path"; then
        mkdir -p "$(dirname "$dest_file")"
    fi
    
    # Perform the transfer based on type and mode
    local transfer_success=false
    
    case "$transfer_type" in
        s3_to_s3)
            if [ "$keep_source" = "true" ]; then
                if aws s3 cp "$source_file" "$dest_file" $storage_class_opt --only-show-errors; then
                    echo "[$(timestamp)] SUCCESS: Copied $filename"
                    transfer_success=true
                fi
            else
                # S3 move: copy with storage class, then delete
                if aws s3 cp "$source_file" "$dest_file" $storage_class_opt --only-show-errors; then
                    if aws s3 rm "$source_file" --only-show-errors; then
                        echo "[$(timestamp)] SUCCESS: Moved $filename"
                        transfer_success=true
                    else
                        echo "[$(timestamp)] WARNING: Copied but failed to delete source: $filename"
                    fi
                fi
            fi
            ;;
        local_to_s3)
            echo "[$(timestamp)] DEBUG: Executing: aws s3 cp \"$source_file\" \"$dest_file\" $storage_class_opt --only-show-errors"
            if aws s3 cp "$source_file" "$dest_file" $storage_class_opt --only-show-errors; then
                if [ "$keep_source" = "true" ]; then
                    echo "[$(timestamp)] SUCCESS: Uploaded $filename"
                else
                    rm -f "$source_file"
                    echo "[$(timestamp)] SUCCESS: Uploaded and removed local $filename"
                fi
                transfer_success=true
            fi
            ;;
        s3_to_local)
            if aws s3 cp "$source_file" "$dest_file" --only-show-errors; then
                if [ "$keep_source" = "true" ]; then
                    echo "[$(timestamp)] SUCCESS: Downloaded $filename"
                else
                    aws s3 rm "$source_file" --only-show-errors
                    echo "[$(timestamp)] SUCCESS: Downloaded and removed S3 $filename"
                fi
                transfer_success=true
            fi
            ;;
        local_to_local)
            if [ "$keep_source" = "true" ]; then
                if cp "$source_file" "$dest_file"; then
                    echo "[$(timestamp)] SUCCESS: Copied $filename"
                    transfer_success=true
                fi
            else
                if mv "$source_file" "$dest_file"; then
                    echo "[$(timestamp)] SUCCESS: Moved $filename"
                    transfer_success=true
                fi
            fi
            ;;
    esac
    
    if [ "$transfer_success" = "true" ]; then
        return 0
    else
        echo "[$(timestamp)] FAILED: Could not transfer $filename"
        return 1
    fi
}

#################### Parse Arguments ####################

# Initialize variables
SOURCE_PATH=""
DEST_PATH=""
FILE_LIST=""
RECURSIVE=false
DRY_RUN=false
KEEP_SOURCE=false
STORAGE_CLASS="STANDARD"

# Parse command line options
while getopts ":hs:d:f:c:rnk" option; do
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
            RECURSIVE=true
            ;;
        n) # Dry run
            DRY_RUN=true
            ;;
        k) # Keep source (copy mode)
            KEEP_SOURCE=true
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

print_header "S3 File Mover"

echo "[$(timestamp)] Job started"
echo "[$(timestamp)] Hostname: $(hostname)"
echo "[$(timestamp)] Working directory: $(pwd)"
echo

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

# Convert and validate destination path
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
    
    if ! validate_local_path "$DEST_PATH" "dest"; then
        exit 1
    fi
fi

echo "[$(timestamp)] Resolved destination: $DEST_PATH ($DEST_TYPE)"
echo "[$(timestamp)] Storage Class: $STORAGE_CLASS"
echo "[$(timestamp)] Recursive: $RECURSIVE"
echo "[$(timestamp)] Dry run: $DRY_RUN"
echo "[$(timestamp)] Keep source: $KEEP_SOURCE"

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

# If source path provided, validate and convert it
if [ -n "$SOURCE_PATH" ]; then
    echo "[$(timestamp)] Original source: $SOURCE_PATH"
    
    if is_s3_path "$SOURCE_PATH"; then
        if ! validate_s3_path "$SOURCE_PATH"; then
            exit 1
        fi
        SOURCE_TYPE="S3"
        # Check if source exists
        if ! check_s3_exists "$SOURCE_PATH"; then
            echo "[$(timestamp)] WARNING: Source path may not exist or may be empty: $SOURCE_PATH"
        fi
    else
        # Local source - convert to absolute path BEFORE validation
        SOURCE_PATH=$(get_absolute_path "$SOURCE_PATH")
        SOURCE_TYPE="Local"
        
        if ! validate_local_path "$SOURCE_PATH" "source"; then
            exit 1
        fi
        
        # Additional check: if source is a directory without -r flag
        if [ -d "$SOURCE_PATH" ] && [ "$RECURSIVE" = false ]; then
            echo "[$(timestamp)] ERROR: Source is a directory. Use -r for recursive mode."
            exit 1
        fi
    fi
    
    echo "[$(timestamp)] Resolved source: $SOURCE_PATH ($SOURCE_TYPE)"
fi

# Determine and display transfer type
if [ -n "$SOURCE_PATH" ]; then
    TRANSFER_TYPE=$(get_transfer_type "$SOURCE_PATH" "$DEST_PATH")
    echo "[$(timestamp)] Transfer type: $TRANSFER_TYPE"
fi

#################### Load AWS CLI ####################

print_header "Environment Setup"

# Determine if we need AWS CLI
NEED_AWS=false
if is_s3_path "$DEST_PATH"; then
    NEED_AWS=true
fi
if [ -n "$SOURCE_PATH" ] && is_s3_path "$SOURCE_PATH"; then
    NEED_AWS=true
fi
if [ -n "$FILE_LIST" ]; then
    # Might have S3 paths in file list, so load AWS CLI to be safe
    NEED_AWS=true
fi

if [ "$NEED_AWS" = true ]; then
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
        
        # Convert to absolute path if it's a relative local path
        if ! is_s3_path "$line"; then
            if [[ ! "$line" =~ ^/ ]]; then
                # Relative path - prepend source path or current directory
                if [ -n "$SOURCE_PATH" ] && ! is_s3_path "$SOURCE_PATH"; then
                    line="${SOURCE_PATH%/}/${line}"
                else
                    line="$(pwd)/${line}"
                fi
            fi
            # Convert to absolute path
            if [ -e "$line" ]; then
                line=$(get_absolute_path "$line")
            fi
        fi
        
        echo "$line" >> "$TEMP_FILE_LIST"
    done < "$FILE_LIST"
fi

# If source path provided and no file list
if [ -n "$SOURCE_PATH" ] && [ -z "$FILE_LIST" ]; then
    if [ "$RECURSIVE" = true ]; then
        echo "[$(timestamp)] Listing files recursively from: $SOURCE_PATH"
        
        if is_s3_path "$SOURCE_PATH"; then
            # S3 recursive listing
            # Extract bucket name
            local_bucket=$(echo "$SOURCE_PATH" | sed 's|s3://||' | cut -d'/' -f1)
            aws s3 ls "$SOURCE_PATH" --recursive | while read -r line; do
                # Skip empty lines
                [ -z "$line" ] && continue
                # Extract the file path (4th field onwards, as paths may have spaces)
                file_path=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | sed 's/^[ ]*//')
                [ -n "$file_path" ] && echo "s3://${local_bucket}/${file_path}" >> "$TEMP_FILE_LIST"
            done
        else
            # Local recursive listing
            find "$SOURCE_PATH" -type f | while read -r file; do
                echo "$file" >> "$TEMP_FILE_LIST"
            done
        fi
    else
        # Single file mode
        if is_s3_path "$SOURCE_PATH"; then
            echo "$SOURCE_PATH" >> "$TEMP_FILE_LIST"
        else
            # For local files, handle both files and directories
            if [ -f "$SOURCE_PATH" ]; then
                echo "$SOURCE_PATH" >> "$TEMP_FILE_LIST"
            elif [ -d "$SOURCE_PATH" ]; then
                echo "[$(timestamp)] ERROR: Source is a directory. Use -r for recursive mode."
                exit 1
            fi
        fi
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
head -5 "$TEMP_FILE_LIST" | while read -r file; do
    echo "  - $file"
done
if [ "$TOTAL_FILES" -gt 5 ]; then
    echo "  ... and $((TOTAL_FILES - 5)) more files"
fi

#################### Create Local Destination Directory ####################

if ! is_s3_path "$DEST_PATH" && [ "$DRY_RUN" = "false" ]; then
    echo
    echo "[$(timestamp)] Creating local destination directory: $DEST_PATH"
    mkdir -p "$DEST_PATH"
fi

#################### Process Files ####################

print_header "Processing Files"

echo "[$(timestamp)] Starting file transfer..."
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
while IFS= read -r source_file || [ -n "$source_file" ]; do
    CURRENT=$((CURRENT + 1))
    
    echo
    echo "------------------------------------------------------------"
    echo "[$(timestamp)] Processing file $CURRENT of $TOTAL_FILES"
    echo ""
    
    # Determine transfer type for this file
    file_transfer_type=$(get_transfer_type "$source_file" "$DEST_PATH")
    
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
    
    # Determine destination path (preserving directory structure for recursive)
    file_dest="$DEST_PATH"
    
    if [ -n "$SOURCE_PATH" ] && [ "$RECURSIVE" = true ]; then
        # For recursive mode, preserve directory structure
        if is_s3_path "$SOURCE_PATH"; then
            # S3 source - extract relative path
            # Remove the s3://bucket/ prefix and the source prefix
            source_prefix="${SOURCE_PATH#s3://}"
            source_prefix="${source_prefix#*/}"  # Remove bucket name
            source_prefix="${source_prefix%/}"   # Remove trailing slash
            
            file_path="${source_file#s3://}"
            file_path="${file_path#*/}"  # Remove bucket name
            
            if [ -n "$source_prefix" ]; then
                relative_path="${file_path#$source_prefix/}"
            else
                relative_path="$file_path"
            fi
        else
            # Local source - extract relative path
            # SOURCE_PATH is already absolute, source_file should also be absolute
            source_base="${SOURCE_PATH%/}"
            relative_path="${source_file#$source_base/}"
        fi
        
        # Build destination with preserved directory structure
        relative_dir=$(dirname "$relative_path")
        if [ "$relative_dir" != "." ]; then
            file_dest="${DEST_PATH%/}/${relative_dir}/"
        fi
        
        # Clean up path
        file_dest=$(echo "$file_dest" | sed 's|/\+|/|g')
    fi
    
    echo "[$(timestamp)] DEBUG: source_file=$source_file"
    echo "[$(timestamp)] DEBUG: file_dest=$file_dest"
    echo "[$(timestamp)] DEBUG: transfer_type=$file_transfer_type"
    
    # Transfer the file
    if transfer_file "$source_file" "$file_dest" "$KEEP_SOURCE" "$DRY_RUN" "$STORAGE_CLASS" "$file_transfer_type"; then
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

print_header "Transfer Summary"

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
echo "  Mode:                  $([ "$KEEP_SOURCE" = true ] && echo "COPY" || echo "MOVE")"
echo "  Storage Class:         $STORAGE_CLASS"
echo "  Dry run:               $DRY_RUN"
echo

# Report failed files if any
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "[$(timestamp)] WARNING: The following files failed to transfer:"
    cat "$FAIL_LOG" | while read -r file; do
        echo "  - $file"
    done
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
