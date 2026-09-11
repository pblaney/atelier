---
layout: script
title: Atelier
description: Merge multiple BAM files into a single BAM file
script_name: bamMerger.sh
category: HPC
tags:
  - bam
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-09-10
---

## Overview

Merges multiple BAM files into a single BAM file and validates the merged BAM integrity.

---

## Usage

``` bash title="bamMerger.sh"
sbatch --job-name=[jobName] ~/atelier/bin/bamMerger.sh -i [inputDir] -o [outputBam] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-i [inputDir]`** | Directory containing BAM files to merge |
| **`-o [outputBam]`** | Output merged BAM file name (or path) |
| **`-n`** | Dry run |
| **`-v`** | Verbose |
| **`-h`** | Display help message |

### Examples

Basic merge to current directory
``` bash
sbatch --job-name=bam-merge ~/atelier/bin/bamMerger.sh \
    -i /path/to/bams/ \
    -o merged.bam
```

Merge to custom output directory
``` bash
sbatch --job-name=bam-merge ~/atelier/bin/bamMerger.sh \
    -i /path/to/bams/ \
    -o /output/merged.bam
```

Dry run preview
``` bash
sbatch --job-name=bam-preview ~/atelier/bin/bamMerger.sh \
    -i /path/to/bams/ \
    -o merged.bam \
    -n
```

---
