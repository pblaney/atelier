---
layout: script
title: Atelier
description: Tidy up BAMs that have unmapped reads with invalid MAPQs
script_name: bamCleaner.sh
category: HPC
tags:
  - bam
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-01-20
---

## Overview

Cleans up BAM files by fixing MAPQ issues in unmapped reads and automatically validates BAM file integrity.

---

## Usage

``` bash title="bamCleaner.sh"
sbatch --job-name=[jobName] ~/atelier/bin/bamCleaner.sh -i [input] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-i [input]`** | Input BAM file or file list (one path per line) |
| **`-o [outputDir]`** | Output directory for cleaned BAMs (default: same as input) |
| **`-p [prefix]`** | Output filename prefix (default: original_name.cleaned) |
| **`-t [threads]`** | Number of threads to use (default: auto-detect) |
| **`-r`** | Remove unmapped reads entirely (default: keep with MAPQ=0) |
| **`-n`** | Dry run |
| **`-h`** | Display help message |

### Examples

Clean a single BAM (automatic validation always happens)
``` bash
sbatch --job-name=clean-bam ~/atelier/bin/bamCleaner.sh \
    -i sample.bam
```

Remove unmapped reads with automatic validation
``` bash
sbatch --job-name=clean-remove ~/atelier/bin/bamCleaner.sh \
    -i sample.bam \
    -r
```

Batch processing with automatic validation
``` bash
sbatch --job-name=clean-batch ~/atelier/bin/bamCleaner.sh \
    -i bam_list.txt
```

Dry run (shows what would happen, including validation)
``` bash
sbatch --job-name=clean-preview ~/atelier/bin/bamCleaner.sh \
    -i sample.bam \
    -n
```

---
