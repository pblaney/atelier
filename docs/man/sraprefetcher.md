---
layout: script
title: Atelier
description: Prefetches SRA data from NCBI using the SRA Toolkit
script_name: sraPrefetcher.sh
category: HPC
tags:
  - sra
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-01-12
---

## Overview

Prefetch SRA data from NCBI using the SRA Toolkit. Supports both public and controlled-access (dbGaP) data.

---

## Usage

``` bash title="sraPrefetcher.sh"
sbatch --job-name=[jobName] ~/atelier/bin/sraPrefetcher.sh -l [accessionList] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-l [accessionList]`** | Text file containing SRA accession IDs (one ID per line) |
| **`-o [outputDir]`** | Output directory for prefetched files (default: current directory) |
| **`-n [ngcFile]`** | Path to .ngc file for dbGaP controlled-access data |
| **`-m [maxSize]`** | Maximum download size (default: 500G) |
| **`-r`** | Resume incomplete downloads |
| **`-d`** | Dry run |
| **`-v`** | Verbose output with debug logging |
| **`-h`** | Display help message |

### Examples

Basic public data prefetch
``` bash
sbatch --job-name=sra-test ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt
```

Download to specific directory
``` bash
sbatch --job-name=sra-download ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt \
    -o /data/sra/
```

Controlled-access data with dbGaP key
``` bash
sbatch --job-name=sra-dbgap ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt \
    -n prj_1234.ngc
```

Custom size and resume
``` bash
sbatch --job-name=sra-large ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt \
    -m 1T \
    -r
```

Verbose/debug mode
``` bash
sbatch --job-name=sra-verbose ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt \
    -v
```

Dry run preview
``` bash
sbatch --job-name=sra-preview ~/atelier/bin/sraPrefetcher.sh \
    -l accessions.txt \
    -d
```

---
