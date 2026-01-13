---
layout: script
title: Atelier
description: Calculates MD5 checksums for files or verifies files against existing checksums
script_name: md5Checker.sh
category: HPC
tags:
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-01-12
---

## Overview

A robust method calculating MD5 checksums for files or verifies files against existing checksums. It supports batch processing via file patterns, file lists, or directory recursion.

---

## Usage

``` bash title="md5Checker.sh"
sbatch --job-name=[jobName] ~/atelier/bin/md5Checker.sh [options] -o [output]
```

### Options

| Option | Description |
|--------|-------------|
| **`-p [pattern]`** | File pattern/glob to match files |
| **`-f [fileList]`** | Text file containing list of file paths (one per line) |
| **`-s [source]`** | Source directory to process |
| **`-o [output]`** | In generate mode, checksum file name; In verify mode, existing checksum file to verify against |
| **`-v`** | Verify mode |
| **`-r`** | Recursive mode |
| **`-n`** | Dry run |
| **`-a`** | Append to existing checksum file |
| **`-h`** | Display help message |

### Examples

Checksum all BAM files in current directory
``` bash
sbatch --job-name=md5-bams md5Checker.sh \
    -p "*.bam" \
    -o project_bams
```

Checksum files recursively in a directory
``` bash
sbatch --job-name=md5-project md5Checker.sh \
    -s /data/project/ \
    -r -o project_backup
```

Checksum files from a list
``` bash
sbatch --job-name=md5-list md5Checker.sh \
    -f files_to_check.txt \
    -o my_files
```

Checksum specific pattern recursively
``` bash
sbatch --job-name=md5-fastq md5Checker.sh \
    -s /data/fastq/ \
    -p "*.fastq.gz" \
    -r -o fastq_files
```

Dry run to preview
``` bash
sbatch --job-name=md5-preview md5Checker.sh \
    -p "*.bam" \
    -o test -n
```

Append to existing checksum file
``` bash
sbatch --job-name=md5-append md5Checker.sh \
    -p "*.cram" \
    -o project_bams -a
```

Verify all files in a checksum file
``` bash
sbatch --job-name=md5-verify md5Checker.sh \
    -v \
    -o md5sums-project_bams.txt
```

Verify only specific files against checksum file
``` bash
sbatch --job-name=md5-verify-bams md5Checker.sh \
    -v \
    -p "*.bam" \
    -o md5sums-project_bams.txt
```

Verify files from a list
``` bash
sbatch --job-name=md5-verify-list md5Checker.sh \
    -v \
    -f files_to_verify.txt\
    -o md5sums-project.txt
```

Dry run verification
``` bash
sbatch --job-name=md5-verify-preview md5Checker.sh \
    -v \
    -o md5sums-project.txt -n
```

---
