# disk-utils

Maintenance, verification and misc disk utilities.

## Scripts

### `hdd_verify.sh`

Checks a (typically used) hard drive before putting it into service. Output and prompts are in Portuguese.

Steps:
1. Identification, safety checks and initial SMART read
2. Short SMART self-test
3. Optional and **destructive**: writes and re-reads the entire disk with `badblocks`
4. Long SMART self-test (the disk reads its own full surface)
5. New SMART read, before/after comparison and verdict

The script refuses to run on disks that are in use (mounted, swap, part of LVM/RAID, or a member of an imported ZFS pool). Reports are written to `/root/verificacao-hd/`. Tests can take hours — run inside `tmux` or `screen`.

Exit codes: `0` passed, `2` passed with warnings, `3` failed, `1` error.

Requirements: `smartmontools` and `e2fsprogs`.

```
Usage: verificar-hd.sh [-d type] [-r reference_disk] [-c] <disk>

  -d type     device type for smartctl (e.g. sat, common for USB docks)
  -r disk     checks that the disk is at least as large as the reference disk
              (e.g. a pool member it will replace)
  -c          full destructive test, with 4 patterns instead of 1
              (about 4x slower)
```
