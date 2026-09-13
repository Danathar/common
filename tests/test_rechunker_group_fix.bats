#!/usr/bin/env bats
# Tests for system_files/shared/usr/bin/rechunker-group-fix
#
# Run: bats tests/test_rechunker_group_fix.bats

SCRIPT="$BATS_TEST_DIRNAME/../system_files/shared/usr/bin/rechunker-group-fix"
WORKDIR=""

setup() {
    WORKDIR="$(mktemp -d)"
    export GROUP_FILE="${WORKDIR}/group"
    export GSHADOW_FILE="${WORKDIR}/gshadow"
}

teardown() {
    rm -rf "${WORKDIR}"
}

# ---------------------------------------------------------------------------
# Basic behaviour
# ---------------------------------------------------------------------------

@test "rechunker-group-fix: appends missing group to empty gshadow" {
    printf 'wheel:x:10:user\n' > "${GROUP_FILE}"
    touch "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -q "^wheel:!\*::" "${GSHADOW_FILE}"
}

@test "rechunker-group-fix: does not duplicate entry already in gshadow" {
    printf 'wheel:x:10:user\n' > "${GROUP_FILE}"
    printf 'wheel:!*::\n' > "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    count=$(grep -c "^wheel:" "${GSHADOW_FILE}")
    [ "${count}" -eq 1 ]
}

@test "rechunker-group-fix: appends only missing entries in multi-group file" {
    printf 'wheel:x:10:\ndocker:x:999:\nvideo:x:44:\n' > "${GROUP_FILE}"
    printf 'wheel:!*::\n' > "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -q "^docker:!\*::" "${GSHADOW_FILE}"
    grep -q "^video:!\*::" "${GSHADOW_FILE}"
    count=$(grep -c "^wheel:" "${GSHADOW_FILE}")
    [ "${count}" -eq 1 ]
}

@test "rechunker-group-fix: handles empty group file gracefully" {
    touch "${GROUP_FILE}"
    touch "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ ! -s "${GSHADOW_FILE}" ]
}

@test "rechunker-group-fix: creates gshadow file if it does not exist" {
    printf 'newgroup:x:500:\n' > "${GROUP_FILE}"
    # GSHADOW_FILE does not exist yet

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ -f "${GSHADOW_FILE}" ]
    grep -q "^newgroup:!\*::" "${GSHADOW_FILE}"
}

@test "rechunker-group-fix: written entry has correct gshadow format (group:!*::)" {
    printf 'testgrp:x:1234:alice,bob\n' > "${GROUP_FILE}"
    touch "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -qE "^testgrp:!\*::$" "${GSHADOW_FILE}"
}

@test "rechunker-group-fix: processes all groups from file with no pre-existing gshadow entries" {
    printf 'alpha:x:1:\nbeta:x:2:\ngamma:x:3:\n' > "${GROUP_FILE}"
    touch "${GSHADOW_FILE}"

    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    grep -q "^alpha:" "${GSHADOW_FILE}"
    grep -q "^beta:" "${GSHADOW_FILE}"
    grep -q "^gamma:" "${GSHADOW_FILE}"
}

# ---------------------------------------------------------------------------
# Service ordering (regression for common#918 / bluefin-lts#628, #585, #466)
# ---------------------------------------------------------------------------

SERVICE="$BATS_TEST_DIRNAME/../system_files/shared/usr/lib/systemd/system/rechunker-group-fix.service"

@test "rechunker-group-fix.service: ordering contract matches systemd-sysusers.service" {
    # Must run before sysusers, after the root fs is writable, and coexist
    # with bootc's own shadow-sync unit.
    grep -qE '^DefaultDependencies=no$' "${SERVICE}"
    grep -qE '^Before=systemd-sysusers\.service$' "${SERVICE}"
    grep -qE '^After=systemd-remount-fs\.service$' "${SERVICE}"
    grep -qE '^After=bootc-sysusers-shadow-sync\.service$' "${SERVICE}"

    # Must not order after (or pull in) local-fs.target: sysusers is ordered
    # before local-fs-pre.target, so that edge closes an ordering cycle.
    run grep -E '^(Wants|Requires|After)=.*\blocal-fs(-pre)?\.target\b' "${SERVICE}"
    [ "${status}" -ne 0 ]

    # Runs before /var is mounted, so it must not run a tmpfiles pass.
    run grep -E '^ExecStart=.*systemd-tmpfiles' "${SERVICE}"
    [ "${status}" -ne 0 ]
}

# Build a minimal unit tree that reproduces the stock systemd early-boot
# ordering the service has to fit into:
#   systemd-sysusers.service < systemd-tmpfiles-setup-dev.service
#     < local-fs-pre.target < local-fs.target
# and let systemd itself compute the start transaction for default.target.
# With After=local-fs.target on the service this reports
# "Found ordering cycle ... rechunker-group-fix.service ..." and deletes a job.
_write_ordering_fixture() {
    local root="$1" unitdir
    unitdir="${root}/usr/lib/systemd/system"
    mkdir -p "${unitdir}/sysinit.target.wants" "${unitdir}/default.target.wants" "${root}/usr/bin"
    cp "${SCRIPT}" "${root}/usr/bin/rechunker-group-fix"
    cp "${SERVICE}" "${unitdir}/rechunker-group-fix.service"

    printf '[Unit]\nDescription=Preparation for Local File Systems\n' \
        > "${unitdir}/local-fs-pre.target"
    printf '[Unit]\nDescription=Local File Systems\nDefaultDependencies=no\nAfter=local-fs-pre.target\n' \
        > "${unitdir}/local-fs.target"
    printf '[Unit]\nDescription=Remount Root and Kernel File Systems\nDefaultDependencies=no\nBefore=local-fs-pre.target local-fs.target\nWants=local-fs-pre.target\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${unitdir}/systemd-remount-fs.service"
    printf '[Unit]\nDescription=Create System Users\nDefaultDependencies=no\nAfter=systemd-remount-fs.service\nBefore=systemd-tmpfiles-setup-dev.service\nBefore=sysinit.target\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${unitdir}/systemd-sysusers.service"
    printf '[Unit]\nDescription=Create Static Device Nodes in /dev\nDefaultDependencies=no\nBefore=sysinit.target local-fs-pre.target systemd-udevd.service\nWants=local-fs-pre.target\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${unitdir}/systemd-tmpfiles-setup-dev.service"
    printf '[Unit]\nDescription=Rule-based Manager for Device Events and Files\nDefaultDependencies=no\nAfter=systemd-sysusers.service\nBefore=sysinit.target\n[Service]\nExecStart=/bin/true\n' \
        > "${unitdir}/systemd-udevd.service"
    printf '[Unit]\nDescription=System Initialization\nDefaultDependencies=no\nWants=local-fs.target\nAfter=local-fs.target\n' \
        > "${unitdir}/sysinit.target"
    printf '[Unit]\nDescription=Default\nRequires=sysinit.target\nAfter=sysinit.target\n' \
        > "${unitdir}/default.target"

    local u
    for u in systemd-sysusers.service systemd-tmpfiles-setup-dev.service systemd-udevd.service; do
        ln -s "../${u}" "${unitdir}/sysinit.target.wants/${u}"
    done
    # WantedBy=default.target from the [Install] section, as `systemctl enable` does.
    ln -s ../rechunker-group-fix.service "${unitdir}/default.target.wants/rechunker-group-fix.service"
}

@test "rechunker-group-fix.service: systemd computes no ordering cycle for the boot transaction" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"

    _write_ordering_fixture "${WORKDIR}/root"

    run systemd-analyze verify --root="${WORKDIR}/root" default.target
    echo "${output}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c -e 'ordering cycle' -e 'deleted to break' <<< "${output}")" -eq 0 ]
}

@test "rechunker-group-fix.service: ordering fixture detects the local-fs.target cycle" {
    # Guard against the fixture silently passing: the pre-fix ordering
    # (After=local-fs.target) must be reported as a cycle by systemd.
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"

    _write_ordering_fixture "${WORKDIR}/root"
    sed -i 's/^After=systemd-remount-fs\.service$/Wants=local-fs.target\nAfter=local-fs.target/' \
        "${WORKDIR}/root/usr/lib/systemd/system/rechunker-group-fix.service"

    run systemd-analyze verify --root="${WORKDIR}/root" default.target
    echo "${output}"
    grep -q 'ordering cycle' <<< "${output}"
    grep -q 'rechunker-group-fix.service' <<< "${output}"
}
