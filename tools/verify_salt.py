#!/usr/bin/env python3
"""Verify the MPC signing salt against Akai's shipped controller checksums.

Usage:
    verify_salt.py [MPC binary] [--pair LABEL LUA INI]...

Salt resolution: MPC_SALT environment variable (36 chars) first, otherwise
extracted from the given MPC binary (MPC_BIN, or the first positional argument).
The salt is never written to disk or printed.

Checks:
  1. The salt is exactly 36 chars (refuse otherwise).
  2. For each shipped pair (default: the pairs under XZT_DIR, if set; otherwise
     pass --pair LABEL LUA INI), sha256(lua_bytes || salt) equals the checksum=
     line in the pair's .ini. Prints PASS/FAIL per build; exits nonzero on
     any FAIL.

See CONTRIBUTING.md for the local reference paths.

FIRMWARE-SPECIFIC: the salt offset 0x5287C10 / build id b'2209920bc0a' are
proven only for MPC 3.10.0.49 Gen2 (md5 15a664f6b6ae591c8b78baae8b376f02).
For any other binary pass MPC_SALT instead of relying on extraction.
"""

import argparse
import hashlib
import os
import sys

SALT_OFFSET = 0x5287C10
SALT_REGION_LEN = 0x25
SALT_LEN = 36
XOR_KEY = 0x5F694973D3C78945
BUILD_ID = b"2209920bc0a"

DEFAULT_BINARY = os.environ.get("MPC_BIN")
# (label, lua, ini): the 3.10.0.49 image pair and the 3.10.1.8 target pair.
# The two .lua payloads are byte-identical, so both inis carry the same
# checksum; checking both still validates the salt against each build's own
# shipped checksum line. Set XZT_DIR to your extracted kit dir (see
# CONTRIBUTING.md), or pass --pair explicitly.
XZT_DIR = os.environ.get("XZT_DIR")
DEFAULT_PAIRS = []
if XZT_DIR:
    DEFAULT_PAIRS = [
        ("3.10.0.49", os.path.join(XZT_DIR, "mpk3100.lua"), os.path.join(XZT_DIR, "mpk3100.ini")),
        ("3.10.1.8", os.path.join(XZT_DIR, "mpkMiniMkIV.lua"), os.path.join(XZT_DIR, "mpkMiniMkIV.ini")),
    ]


def die(message: str, code: int = 1) -> None:
    print(f"verify_salt: error: {message}", file=sys.stderr)
    sys.exit(code)


def xor_decode(encoded: bytes) -> bytes:
    return bytes(
        b ^ ((XOR_KEY >> (8 * (i % 8))) & 0xFF) for i, b in enumerate(encoded)
    )


def binary_contains_build_id(path: str) -> bool:
    chunk_size = 1 << 20
    overlap = len(BUILD_ID) - 1
    tail = b""
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                return False
            window = tail + chunk
            if BUILD_ID in window:
                return True
            tail = window[-overlap:]
    return False


def salt_from_binary(binary_path: str) -> bytes:
    if not os.path.isfile(binary_path):
        die(f"MPC binary not found: {binary_path}")
    if not binary_contains_build_id(binary_path):
        die(
            f"build id {BUILD_ID.decode()!r} not found in {binary_path}; "
            "the salt offset is only proven for the 3.10.0.49 Gen2 binary. "
            "Pass MPC_SALT instead."
        )
    with open(binary_path, "rb") as handle:
        handle.seek(SALT_OFFSET)
        encoded = handle.read(SALT_REGION_LEN)
    if len(encoded) != SALT_REGION_LEN:
        die(f"could not read {SALT_REGION_LEN} bytes at offset {SALT_OFFSET:#x}")
    salt = xor_decode(encoded).split(b"\x00")[0]
    try:
        salt.decode("ascii")
    except UnicodeDecodeError:
        die(
            f"decoded bytes at offset {SALT_OFFSET:#x} are not ASCII; "
            "pass MPC_SALT instead"
        )
    return salt


def resolve_salt(binary_path: str) -> bytes:
    env_salt = os.environ.get("MPC_SALT")
    if env_salt is not None:
        if len(env_salt) != SALT_LEN:
            die(
                f"MPC_SALT is {len(env_salt)} chars, expected {SALT_LEN}; "
                "refusing to fall back silently."
            )
        try:
            env_salt.encode("ascii")
        except UnicodeEncodeError:
            die("MPC_SALT must be ASCII")
        return env_salt.encode("ascii")
    return salt_from_binary(binary_path)


def checksum_from_ini(ini_path: str) -> str:
    with open(ini_path, "rb") as handle:
        text = handle.read().decode("utf-8")
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("checksum"):
            _, _, value = stripped.partition("=")
            return value.strip().lower()
    die(f"no checksum= line in {ini_path}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Verify the MPC signing salt against shipped checksums."
    )
    parser.add_argument("binary", nargs="?", default=DEFAULT_BINARY)
    parser.add_argument(
        "--pair",
        action="append",
        nargs=3,
        metavar=("LABEL", "LUA", "INI"),
        help="extra checksum pair to verify (repeatable); "
        "defaults to the 3.10.0.49 and 3.10.1 mpkMiniMkIV pairs",
    )
    options = parser.parse_args()

    salt = resolve_salt(options.binary)
    if len(salt) != SALT_LEN:
        die(f"salt length is {len(salt)}, expected {SALT_LEN}; refusing")

    pairs = options.pair if options.pair else DEFAULT_PAIRS
    failures = 0
    for label, lua_path, ini_path in pairs:
        if not os.path.isfile(lua_path):
            die(f"lua not found for {label}: {lua_path}")
        if not os.path.isfile(ini_path):
            die(f"ini not found for {label}: {ini_path}")
        with open(lua_path, "rb") as handle:
            lua_bytes = handle.read()
        expected = checksum_from_ini(ini_path)
        actual = hashlib.sha256(lua_bytes + salt).hexdigest()
        if actual == expected:
            print(f"{label}: PASS ({lua_path} + salt == checksum= in {ini_path})")
        else:
            failures += 1
            print(
                f"{label}: FAIL (sha256(lua + salt)={actual}, "
                f"checksum= in {ini_path}={expected})"
            )

    if failures:
        die(f"{failures} checksum mismatch(es); salt rejected", code=1)
    print("verify_salt: all builds PASS")


if __name__ == "__main__":
    main()
