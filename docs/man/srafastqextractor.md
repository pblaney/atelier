---
layout: script
title: Atelier
description: Extracts FASTQs from prefetched SRA data using the SRA Toolkit
script_name: sraFastqExtractor.sh
category: HPC
tags:
  - sra
  - hpc
  - batch-processing
  - slurm
last_updated: 2026-01-29
---

## Overview

Extract FASTQ files from prefetched SRA data using fasterq-dump. Supports both public and controlled-access (dbGaP) data.

---

## Usage

``` bash title="sraFastqExtractor.sh"
sbatch --job-name=[jobName] ~/atelier/bin/sraFastqExtractor.sh -l [accessionList] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-l [accessionList]`** | Text file containing SRA accession IDs (one ID per line). Assumes accessions are in subdirectories with prefetched .sra files |
| **`-b [baseDir]`** | ase directory containing accession subdirectories (default: current directory) |
| **`-n [ngcFile]`** | Path to .ngc file for dbGaP controlled-access data |
| **`-d`** | Dry run |
| **`-v`** | Verbose output with debug logging |
| **`-h`** | Display help message |

### Examples

Basic extraction from public data
``` bash
sbatch --job-name=fastq-extract ~/atelier/bin/sraFastqExtractor.sh \
    -l accessions.txt
```

Extract controlled-access data
``` bash
sbatch --job-name=fastq-dbgap ~/atelier/bin/sraFastqExtractor.sh \
    -l accessions.txt \
    -n ~/prj_1234.ngc
```

Dry run preview
``` bash
sbatch --job-name=fastq-preview ~/atelier/bin/sraFastqExtractor.sh \
    -l accessions.txt \
    -d
```

Verbose/debug mode
``` bash
sbatch --job-name=fastq-verbose ~/atelier/bin/sraFastqExtractor.sh \
    -l accessions.txt \
    -v
```

---
