# Install + signing

Target: MPC 3.10.1.8 (build 38fdde70994), MPC Live III Gen2.

Citations to FINDINGS refer to the mpc-controllers findings doc (see CONTRIBUTING.md).

## 1. The pair

A controller script is a `.ini` + `.lua` pair:

- `LaunchpadMiniMK3.ini` — `[info]` first line, `input=` / `output=` port-name matches
  (order = port index used by `midiOut.Send*`), `script=`, `scriptVersion=`, `checksum=`.
- `LaunchpadMiniMK3.lua` — the script.

The `.ini` must start with `[info]`; otherwise MPC reads it but ignores it and never opens
the `.lua` (FINDINGS 18).

## 2. Sign

`checksum = sha256(lua_bytes || 36-char salt)`. The salt lives XOR-obfuscated in the MPC
binary; read it from your own copy, never publish it.

```sh
MPC_BIN=/path/to/your/MPC ./script/build.sh
```

`tools/sign_script.py` reads the salt from the 3.10.0.49 Gen2 binary at file offset
`0x5287C10` (build id `2209920bc0a`), XOR-decodes it with key `0x5F694973D3C78945`, and
rewrites the `checksum=` line. The same salt gives the correct checksum for Akai's shipped
`mpkMiniMkIV.lua` on 3.10.1.8 (verified: `tools/verify_salt.py` PASS on both builds).

If you have a different build, pass `MPC_SALT` (36 chars) instead of a binary.

## 3. Copy to the device

The release zip (`mpc-launchpad-mini-mk3-v<version>.zip`) contains the signed
`.ini`, the minified `.lua`, this guide, the README and the generated
`MANUAL.md` control reference.

Search dirs (FINDINGS §1):

- `/usr/share/Akai/SME0/Devices` (read-only rootfs; not for user scripts)
- `<user root>/MPC Documents/Devices` — user root is `/storage`, `/data/UserData`, `/nvme`
  or `/sdcard` depending on the device. On the Live III it is normally
  `/nvme/MPC Documents/Devices/`.

```sh
mkdir -p "/nvme/MPC Documents/Devices/LaunchpadMiniMK3"
cp LaunchpadMiniMK3.ini LaunchpadMiniMK3.lua "/nvme/MPC Documents/Devices/LaunchpadMiniMK3/"
```

## 4. Verify it loaded

```sh
journalctl -u acvs -o cat --no-pager | grep LaunchpadMiniMK3
```

Expected first lines: `LaunchpadMiniMK3: aperture ok`, `clipProperties ok`, `loaded`.
If you see `aperture MISSING`, the clip surface is disabled but the script still runs
(transport/track row/function buttons continue).

## 5. Rollback

Remove the folder and restart MPC (or reload the device script list):

```sh
rm -rf "/nvme/MPC Documents/Devices/LaunchpadMiniMK3"
```

The script never writes to the MPC project; removing it restores the stock behaviour.

## 6. Notes

- The LPMiniMK3 boots into Live mode. The script sends the readback queries
  `F0 00 20 29 02 0D 0E F7` (mode), `... 0D 00 F7` (layout) and `... 0D 0A F7`
  (LED feedback), captures the prior state from the replies, then sends
  `F0 00 20 29 02 0D 0E 01 F7` (Programmer mode) plus `... 0D 0A 00 01 F7`
  (internal feedback off) on the first timer tick. On unload it restores the
  captured mode/layout (default Live + 0x04 Custom 1/Drums if the queries did not
  answer) and the prior LED feedback. Journal lines: `prior mode 0x00`,
  `prior layout 0x04`, `programmer mode`, `restored live mode`.
- The checksum is skipped when the hardware product code is 0 (desktop MPC software).
- Never commit the salt or Akai binaries.
