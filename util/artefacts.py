#!/usr/bin/env python
# Copyright lowRISC and contributors (COSMIC project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# This script is used auto-generated and vendor files to the repository.
# If the check flag is provided it will verify that all auto-generated and vendored files committed
# to the repository are not stale and match the generated output of the programs used to create
# them.
# This consists of lockfiles, generated hardware components (e.g. crossbars), and hardware
# components vendored and patched with `vendor.py`.

import argparse
import subprocess
import sys

# the commands which generated committed files to be ran
COMMANDS: list[list[str]] = [
    # lockfiles
    ["uv", "lock"],
    # Skip checking the Nix flake lock because Nix is not yet available in CI
    # TODO: Uncomment when Nix is usable in CI
    # ["nix", "flake", "lock"],
    # Generate rdl from hjson
    [
        "vendor/opentitan/util/regtool.py",
        "--systemrdl",
        "-o",
        "hw/ip/uart16550/rdl/uart16550_main.rdl",
        "hw/ip/uart16550/data/uart16550_main.hjson"
    ],
    [
        "vendor/opentitan/util/regtool.py",
        "--systemrdl",
        "-o",
        "hw/ip/uart16550/rdl/uart16550_wo.rdl",
        "hw/ip/uart16550/data/uart16550_wo.hjson"
    ],
    [
        "vendor/opentitan/util/regtool.py",
        "--systemrdl",
        "-o",
        "hw/ip/uart16550/rdl/uart16550_dl.rdl",
        "hw/ip/uart16550/data/uart16550_dl.hjson"
    ],
    # vendored hardware dependencies
    ["util/vendor.py", "vendor/opentitan.vendor.hjson"],
]


def run_subprocess(cmdline: list[str]):
    try:
        proc = subprocess.run(cmdline, capture_output=True, check=False)
        if proc.returncode != 0:
            joined_cmdline = " ".join(cmdline)
            print(f"command {joined_cmdline} exited with non-zero exit code {proc.returncode}")
        if proc.stdout:
            print(proc.stdout.decode(), end="")
        if proc.stderr:
            print(proc.stderr.decode(), end="")
        if proc.returncode != 0:
            sys.exit(1)
    except OSError as e:
        print(f"failed to run process '{cmdline[0]}': {e.strerror}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Artefacts generator utility")
    parser.add_argument("--check", action="store_true", help="Perform a validation check.")
    args = parser.parse_args()

    fail = False
    for cmdline in COMMANDS:
        # run each generator command. these should all succeed
        joined_cmdline = " ".join(cmdline)
        print(f"running '{joined_cmdline}'...")
        run_subprocess(cmdline)

        if not args.check:
            continue

        # check if anything is different by running `git status` and
        # checking if there is any output. we let all the steps run before
        # returning with failure or success, so that the non-matching files
        # after all steps are shown
        try:
            git_status = subprocess.run(
                ["git", "status", "--porcelain"],
                capture_output=True,
                check=False,
            )
            if git_status.stdout:
                fail = True
                print("git tree is dirty!")
                print(git_status.stdout.decode(), end="")
        except OSError as e:
            print(f"failed to run 'git status': {e.strerror}")
            sys.exit(1)

    if args.check and fail:
        print("committed auto-generated files do not match!")
        sys.exit(1)


if __name__ == "__main__":
    main()
