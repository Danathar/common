---
name: submodule-boundary
version: "1.0"
last_updated: "2026-06-23"
id: submodule-boundary
one_line_purpose: Decide where a system_files change belongs across variants.
entry_point: docs/skills/submodule-boundary.md
category: meta
mcp_compliance_level: partial
optimization_status: draft
status: active
dependencies: []
tags: [submodules, git, architecture]
description: >-
  system_files scope boundary. Use when editing system_files/shared/,
  bluefin/, nvidia/, or deciding where a system file change belongs.
metadata:
  type: reference
---

# system_files scope — what is editable where

## Summary

`system_files/shared/` is now a **directly tracked directory** in this repo. It was previously a read-only bind from the `aurorafin-shared` submodule, but that dependency has been severed. You can now edit files in `system_files/shared/` directly in PRs to this repo.

`system_files/bluefin/` remains the editable path for Bluefin-specific config.
`system_files/nvidia/` contains NVIDIA-specific overlays and is also directly tracked here.

## Editable paths

| Path | Editable? | Notes |
|---|---|---|
| `system_files/shared/**` | ✅ Yes | Directly tracked — edit here |
| `system_files/bluefin/**` | ✅ Yes | Bluefin-specific config |
| `system_files/nvidia/**` | ✅ Yes | NVIDIA overlay |
| `bluefin-branding/**` | ❌ No | Submodule — `projectbluefin/branding` |

## What changed

Previously, `system_files/shared/` was materialized from a `ublue-os/aurorafin-shared` git submodule. The `validate.yml` workflow enforced that `system_files/shared/` could not be edited directly. **That constraint is gone.** The submodule has been removed and the files are now owned here.

## Submodule that remains

Only `bluefin-branding` remains as a submodule:
```
bluefin-branding → projectbluefin/branding (wallpapers, logos)
```

## Local testing without a full build

Use `just overlay` to test `system_files/` changes as a systemd-sysext on a running Bluefin system, without building the full OCI image. See [`containerfile/SKILL.md`](containerfile/SKILL.md) for the full recipe, SELinux requirements, and activation steps.

## Dakota exclusion pattern

`system_files/shared/` flows into **bluefin, bluefin-lts, and dakota** via the common OCI context. Dakota's `elements/bluefin/common.bst` does a plain `cp -r system_files/shared/usr/` — it receives everything.

If you add a file to `system_files/shared/` that should **not** appear in dakota (e.g., a migration aid that only applies to users rebasing from legacy-rechunk images), add explicit `rm -f` lines to `dakota/elements/bluefin/common.bst` immediately after the copy block:

```yaml
# Dakota is a fresh BuildStream image — strip files that only apply to
# users migrating from legacy ublue-os/rechunk-based images.
rm -f "%{install-root}%{prefix}/bin/rechunker-group-fix"
rm -f "%{install-root}%{prefix}/lib/systemd/system/rechunker-group-fix.service"
rm -f "%{install-root}%{prefix}/lib/systemd/system-preset/00-rechunker-group-fix.preset"
```

**Current exclusions in `common.bst`:** `rechunker-group-fix` (script + service + preset) — migration aid for legacy rechunk-based image rebases; not needed on a fresh dakota install.

## rechunker-group-fix — architecture and fix history

### What it does

`rechunker-group-fix` ensures that users rebasing from images built with `nss-altfiles` (groups stored in `/usr/lib/group`) do not break their gshadow file when switching to an image that uses `/etc/group`. Without it, missing gshadow entries cause black screens and non-booting systems.

Key files (all live in `system_files/shared/`):
- `usr/bin/rechunker-group-fix` — script that syncs group→gshadow entries
- `usr/lib/systemd/system/rechunker-group-fix.service` — service that runs the script at boot
- `usr/lib/systemd/system-preset/00-rechunker-group-fix.preset` — enables the service on install

### Service ordering (critical — do not change without understanding this)

The service must run with:

```ini
DefaultDependencies=no
After=systemd-remount-fs.service
After=bootc-sysusers-shadow-sync.service
Before=systemd-sysusers.service
```

**Why:** `systemd-sysusers` is what fails if gshadow is corrupt. The service must run *before* sysusers, not after, under the same preconditions sysusers itself requires (`After=systemd-remount-fs.service`, so `/etc` is writable). `bootc-sysusers-shadow-sync.service` is the upstream fix shipped in bootc ≥1.16 ([bootc#2207](https://github.com/bootc-dev/bootc/pull/2207), merged May 2025); our service must run after it so they coexist correctly. `DefaultDependencies=no` is required for any early-boot unit.

**Never add `Wants=local-fs.target` / `After=local-fs.target`** (the ordering [common#530](https://github.com/projectbluefin/common/pull/530) shipped with). `systemd-sysusers.service` is ordered before `systemd-tmpfiles-setup-dev.service`, which is ordered before `local-fs-pre.target`, which is ordered before `local-fs.target`, so that edge closes an ordering cycle:

```text
Found ordering cycle on systemd-sysusers.service/start; has dependency on rechunker-group-fix.service/start, local-fs.target/start, local-fs-pre.target/start, systemd-tmpfiles-setup-dev.service/start
```

systemd breaks the cycle by deleting whichever job it reaches first — `systemd-udevd`, `systemd-sysusers`, `systemd-tmpfiles-setup-dev`, `local-fs-pre.target`, `systemd-ask-password-console.path` (the LUKS password agent), … — so the failure is per-boot nondeterministic: 90 s device timeouts, `/var` never mounted, encrypted volumes never unlocked, or a black screen ([common#918](https://github.com/projectbluefin/common/issues/918), [bluefin-lts#628](https://github.com/projectbluefin/bluefin-lts/issues/628), [bluefin-lts#585](https://github.com/projectbluefin/bluefin-lts/issues/585), [bluefin-lts#466](https://github.com/projectbluefin/bluefin-lts/issues/466)).

Because the unit runs before `local-fs-pre.target`, it must not run `systemd-tmpfiles`: `/var` and `/tmp` are not mounted yet and the pass exits 65. `systemd-tmpfiles-setup.service` performs the same pass after `local-fs.target` and after `systemd-sysusers.service`.

`tests/test_rechunker_group_fix.bats` enforces this contract statically and by letting `systemd-analyze verify --root=` compute the boot transaction against a minimal fixture of the stock early-boot units. Downstream images must not try to fix ordering with a drop-in: systemd cannot reset `After=`/`Wants=` from a drop-in (`After=` with an empty value is a no-op for dependencies), so a drop-in can only *add* edges — `Before=local-fs-pre.target` on top of the old `After=local-fs.target` produced a tighter cycle.

### flock on gshadow writes (required)

The script wraps all gshadow writes in `flock -x 9` to prevent corruption from concurrent access:

```bash
(
    flock -x 9
    while IFS=: read -r group_name _rest; do
        grep -q "^${group_name}:" "$GSHADOW_FILE" 2>/dev/null || \
            printf '%s:!*::\n' "$group_name" >> "$GSHADOW_FILE"
    done < "$GROUP_FILE"
) 9>>"${GSHADOW_FILE}"
```

Do not remove the flock — concurrent sysusers runs can corrupt the file.

### Repo-level duplication history

**bluefin** previously had its own copy of these files in `system_files/shared/`, which *shadowed* common's version and prevented common's fixes from taking effect. This was removed in [bluefin#439](https://github.com/projectbluefin/bluefin/pull/439).

**bluefin-lts** has never had its own copy — it has always deferred to common. No removal needed.

**dakota** actively strips these files (see exclusion pattern above) since it is a fresh BuildStream image and the migration path does not apply.

**Future agents:** If you need to change the rechunker service ordering or script behavior, edit only `system_files/shared/` in this repo. Check that no consuming repo (bluefin, bluefin-lts) has re-introduced a shadowing copy before declaring the fix applied.
