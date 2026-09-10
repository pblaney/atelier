---
layout: script
title: Atelier
description: Converts CRAM files to BAM format
script_name: bamCleaner.sh
category: HPC
tags:
  - bam
  - cram
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-09-10
---

## Overview

Converts CRAM files to BAM format using hg38 as reference and validate the converted files.

---

## Usage

``` bash title="cramConverter.sh"
sbatch --job-name=[jobName] ~/atelier/bin/cramConverter.sh -i [inputDir] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-i [inputDir]`** | Directory containing CRAM files to convert |
| **`-o [outputDir]`** | Output directory for converted BAM files (default: `inputDir`/convertedBams) |
| **`-r [reference]`** | Path to reference genome FASTA (default: /gpfs/data/morganlab/referenceFiles/hg38/Homo_sapiens_assembly38.fasta) |
| **`-n`** | Dry run |
| **`-v`** | Verbose |
| **`-h`** | Display help message |

### Examples

Basic conversion to default output
``` bash
sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh \
    -i /path/to/crams/
```

Convert to custom output directory
``` bash
sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh \
    -i /path/to/crams/ \
    -o /custom/output/
```

Use custom reference genome
``` bash
sbatch --job-name=cram-convert ~/atelier/bin/cramConverter.sh \
    -i /path/to/crams/ \
    -r /path/to/ref.fasta
```

Dry run
``` bash
sbatch --job-name=cram-preview ~/atelier/bin/cramConverter.sh \
    -i /path/to/crams/ \
    -n
```

---
