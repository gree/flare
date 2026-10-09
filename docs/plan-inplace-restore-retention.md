# In-place restore that keeps the live copy — minimal plan

Status: **plan, not implemented** (2026-10-09). Today `flare-restore-hook`
checks the backup's partition binding and then REPLACES the live copy
(`rm -rf` + `cp -a`) with nothing kept. This plan reuses the existing copy
retention (the staged copy switch, `src/lib/copy_switch.h`) instead of adding
a second mechanism.

## What is reused

| Existing piece | Used for |
|---|---|
| `staging-<attempt>` directory in the data dir | the backup copy, placed next to the live one (same filesystem by construction) |
| switch intent (`attempt`, `old_id`, `new_id`, phase), fsync'd | written BEFORE any rename |
| renames live -> `retained-<attempt>`, staging -> live, `fsync_dir` | the switch itself |
| crash recovery at open (`abort` / `rollback` / `roll_forward` / `stop`) | a crash at any point of the switch |
| retained copies without a retained record are never reaped (`retained_deletable`: "no record of a verified switch (approval needed)") | the replaced copy is KEPT until an explicit `FlareCopyDiscardApproval` |
| `rebuild_space_available` / reserve (`capacity_watch_ok`) | capacity gate |
| `RESTORED` marker semantics (new identity, unverified until the map makes it the master of its binding) | unchanged |

## Minimal change

1. **Hook** (`flare-restore-hook`): after the provenance check, copy the
   checkpoint to `<data>/staging-restore-<ts>` (not over the live copy), only
   if `free >= size(checkpoint) + reserve` (statvfs of the data dir; on tmpfs
   that is the memory limit — double memory is the real cost); write
   `RESTORED` into the staging copy and a `RESTORE.switch` marker naming it.
   No `rm -rf`. A refused capacity check = refused restore (live copy kept).
2. **flared at open** (C++): if `RESTORE.switch` names a staging copy, run the
   existing switch with a `restore` attempt id: intent -> rename live to
   `retained-restore-<ts>` -> rename staging to live -> fsync -> drop intent.
   **No retained record is written**, so the reaper never deletes the old copy.
   A crash anywhere is resolved by the existing recovery at the next open.
3. **Discard**: only through the existing `FlareCopyDiscardApproval` path
   (operator, human approval). No automatic deletion.
4. **Roll back**: documented procedure = the same switch in reverse
   (retained -> live), refused while the restored copy is a verified master.

## Open specifications (need decisions; fail-closed until then)

- Whether a VERIFIED restore may ever let its retained copy be deleted
  automatically (default here: never; approval only).
- Capacity: is `size(checkpoint) + reserve` enough on tmpfs (memory limit),
  and what happens when two pods of a partition restore at once.
- Roll-back authority: who may switch back, and how the operator's history
  record is told (a rolled-back copy is another history: approval needed).
- Interaction with the authoritative history (R8): an in-place restore is a
  deliberate history change; adopting it still needs the approval path.
- Old backups without a partition binding: refused (compatibility decision
  pending).

## Tests to add with the implementation

- crash after intent / after first rename / after second rename -> recovery
  outcome per phase (C++, reusing the copy-switch crash tests);
- capacity refused -> live copy untouched, `RESTORE.refused`;
- the retained copy survives the reaper (no record) and is removed only by an
  approval;
- E2E: in-place restore keeps `retained-restore-*` and the old data in it.
