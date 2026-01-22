---
layout: script
title: Atelier
description: Rename files at scale
script_name: fileRenamer.sh
category: HPC
tags:
  - hpc
last_updated: 2026-01-22
---

## Overview

Rename large sets of files.

---

## Usage

``` bash title="fileRenamer.sh"
~/atelier/bin/fileRenamer.sh -f [mappingFile] [options]
```

### Options

| Option | Description |
|--------|-------------|
| **`-f [mappingFile]`** | Text file with old and new filenames with format old_name<TAB>new_name (one path per line) |
| **`-d [sourceDir]`** | Source directory for files (default: current directory) |
| **`-n`** | Dry run |
| **`-v`** | Verbose output with debug logging |
| **`-h`** | Display help message |

### Examples

Basic rename
``` bash
~/atelier/bin/fileRenamer.sh -f rename_list.txt
```

Dry run preview
``` bash
~/atelier/bin/fileRenamer.sh -f rename_list.txt -n
```

Rename files in specific directory
``` bash
~/atelier/bin/fileRenamer.sh -f rename_list.txt -d /data/samples/
```

Verbose with dry run
``` bash
~/atelier/bin/fileRenamer.sh -f rename_list.txt -n -v
```

---
