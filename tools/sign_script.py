#!/usr/bin/env python3
"""Sign an MPC Lua controller script: checksum = sha256(lua_bytes || salt).

Usage:
    sign_script.py <MPC binary> <script.lua> [script.ini]

Salt resolution (first match wins):
  1. MPC_SALT environment variable (must be exactly 36 chars).
  2. Extracted from the owner's own MPC binary at run time.

The salt is never written to disk and never printed by this tool. Only the
resulting 64-hex-digit digest is printed on stdout (stderr carries status).

Provenance of the checksum rule (verified against local artifacts, see
tools/test-sign.sh):
  - checksum = sha256(lua_bytes || salt), salt 36 ASCII chars.
    Verified: Akai's shipped mpkMiniMkIV.lua hashes to the checksum= line in
    the matching shipped mpkMiniMkIV.ini when salted with the value decoded
    below.
  - The salt is XOR-obfuscated inside the MPC binary with key
    0x5F694973D3C78945, byte schedule key_byte[i] = (KEY >> (8*(i%8))) & 0xFF
    (little-endian 64-bit key), stored as 0x25 bytes (36 chars + trailing NUL).

FIRMWARE-SPECIFIC: the salt offset 0x5287C10 and the build id b'2209920bc0a'
are proven ONLY for the MPC 3.10.0.49 Gen2 binary with
md5 15a664f6b6ae591c8b78baae8b376f02. The salt is NOT at that offset in the
3.10.1 binary; for other builds pass MPC_SALT instead of relying on extraction.
"""

import hashlib
import os
import re
import sys

SALT_OFFSET = 0x5287C10      # file offset of the encoded salt
SALT_REGION_LEN = 0x25       # 36 salt chars + trailing NUL
SALT_LEN = 36
XOR_KEY = 0x5F694973D3C78945
BUILD_ID = b"2209920bc0a"    # markers this salt offset has been proven against
CHECKSUM_KEY_RE = re.compile(r"^[ \t]*checksum[ \t]*=", re.IGNORECASE)


def die(message: int, code: int = 1) -> None:
    print(f"sign_script: error: {message}", file=sys.stderr)
    sys.exit(code)


def xor_decode(encoded: bytes) -> bytes:
    """Undo the in-binary XOR obfuscation of the salt."""
    return bytes(
        b ^ ((XOR_KEY >> (8 * (i % 8))) & 0xFF) for i, b in enumerate(encoded)
    )


def binary_contains_build_id(path: str) -> bool:
    """Stream-search the binary for the build id without loading it fully."""
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
            "this salt offset is only proven for that binary. "
            "Refusing to guess. Pass MPC_SALT instead."
        )
    with open(binary_path, "rb") as handle:
        handle.seek(SALT_OFFSET)
        encoded = handle.read(SALT_REGION_LEN)
    if len(encoded) != SALT_REGION_LEN:
        die(f"could not read {SALT_REGION_LEN} bytes at offset {SALT_OFFSET:#x}")
    decoded = xor_decode(encoded)
    salt = decoded.split(b"\x00")[0]
    try:
        salt.decode("ascii")
    except UnicodeDecodeError:
        die(
            f"decoded bytes at offset {SALT_OFFSET:#x} are not ASCII; "
            "the binary layout does not match. Pass MPC_SALT instead."
        )
    if len(salt) != SALT_LEN:
        die(
            f"decoded salt at offset {SALT_OFFSET:#x} is {len(salt)} chars, "
            f"expected {SALT_LEN}. Pass MPC_SALT instead."
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


def rewrite_ini(ini_path: str, digest: str) -> None:
    """Replace the checksum= line, adding one at the end if absent."""
    with open(ini_path, "rb") as handle:
        raw = handle.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        die(f"{ini_path} is not valid UTF-8")

    lines = text.splitlines(keepends=True)
    replaced = False
    for index, line in enumerate(lines):
        if CHECKSUM_KEY_RE.match(line):
            if line.endswith("\r\n"):
                eol = "\r\n"
            elif line.endswith("\n"):
                eol = "\n"
            else:
                eol = ""
            lines[index] = f"checksum={digest}{eol}"
            replaced = True
            break
    if not replaced:
        if lines and not lines[-1].endswith(("\n", "\r\n")):
            lines[-1] += "\n"
        lines.append(f"checksum={digest}\n")

    with open(ini_path, "wb") as handle:
        handle.write("".join(lines).encode("utf-8"))
    print(
        f"sign_script: {'rewrote' if replaced else 'added'} checksum= in {ini_path}",
        file=sys.stderr,
    )


def main() -> None:
    args = sys.argv[1:]
    if len(args) < 2 or len(args) > 3 or args[0] in ("-h", "--help"):
        print(
            "usage: sign_script.py <MPC binary> <script.lua> [script.ini]",
            file=sys.stderr,
        )
        sys.exit(2)

    binary_path, lua_path = args[0], args[1]
    ini_path = args[2] if len(args) == 3 else None

    salt = resolve_salt(binary_path)

    if not os.path.isfile(lua_path):
        die(f"lua script not found: {lua_path}")
    with open(lua_path, "rb") as handle:
        lua_bytes = handle.read()
    if not lua_bytes:
        die(f"lua script is empty: {lua_path}")

    digest = hashlib.sha256(lua_bytes + salt).hexdigest()

    if ini_path is not None:
        if not os.path.isfile(ini_path):
            die(f"ini script not found: {ini_path}")
        rewrite_ini(ini_path, digest)

    print(digest)


if __name__ == "__main__":
    main()
