---
layout: script
title: Atelier
description: Move or copy files between local and S3 bucket locations with batch processing support
script_name: s3Mover.sh
category: AWS
tags:
  - aws
  - s3
  - file-transfer
  - batch-processing
  - slurm
last_updated: 2026-01-09
---

## Overview

Bidirectional transfer support between local and Amazon S3 locations. It supports batch processing of multiple files, recursive directory operations, and includes comprehensive progress reporting suitable for long-running SLURM jobs.

---

## Usage

``` bash title="s3Mover.sh" 
sbatch --job-name=[jobName] ~/atelier/bin/s3Mover.sh -s [source] -d [dest] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-s [source]`** | Source path - can be: S3 URI or Local path |
| **`-d [dest]`** | Destination path - can be: S3 URI or Local path |
| **`-f [fileList]`** | Text file containing list of file paths to transfer (one per line) |
| **`-r`** | Recursive mode - transfer all files in source directory |
| **`-n`** | Dry run - preview without making changes |
| **`-c [class]`** | S3 storage class for uploads (default: STANDARD; avail: GLACIER, DEEP_ARCHIVE) |
| **`-h`** | Display help message |

### Examples

Upload a local file to S3
``` bash
sbatch --job-name=upload ~/atelier/bin/s3Mover.sh \
    -s /data/sample.bam \
    -d s3://mybucket/data/
```

Upload with GLACIER storage class
``` bash
sbatch --job-name=archive ~/atelier/bin/s3Mover.sh \
    -s /data/sample.bam \
    -d s3://mybucket/archive/ \
    -c GLACIER
```

Upload directory recursively to DEEP_ARCHIVE
``` bash
sbatch --job-name=archive ~/atelier/bin/s3Mover.sh \
    -s /data/sample.bam \
    -d s3://mybucket/archive/ \
    -r -c DEEP_ARCHIVE
```

Download from S3 to local
``` bash
sbatch --job-name=download ~/atelier/bin/s3Mover.sh \
    -s s3://mybucket/data/file.bam \
    -d /local/data/
```

Download S3 directory recursively
``` bash
sbatch --job-name=download-dir ~/atelier/bin/s3Mover.sh \
    -s s3://mybucket/data/project/ \
    -d /local/data/project/ \
    -r
```

Move files within S3
``` bash
sbatch --job-name=s3move ~/atelier/bin/s3Mover.sh \
    -s s3://mybucket/data/file.bam \
    -d s3://mybucket/archive/
```

Transfer files from a list (mixed local/S3 sources)
``` bash
sbatch --job-name=batch ~/atelier/bin/s3Mover.sh \
    -f files_to_transfer.txt \
    -d s3://mybucket/archive/
```

Dry run to preview operations
``` bash
sbatch --job-name=preview ~/atelier/bin/s3Mover.sh \
    -s /data/project/ \
    -d s3://mybucket/data/ \
    -r -c DEEP_ARCHIVE -n
```

---
