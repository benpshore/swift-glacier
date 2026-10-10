# swift-glacier

swift-glacier

## Checks

Run these before opening a PR. CI runs the same ones.

```sh
uv run ruff format && uv run ruff check && uv run pytest && uv audit --preview-features audit-command
cargo fmt && cargo clippy --all-targets -- -D warnings && cargo test
swift build && swift test
npm run lint && npm test
npm run lint:css
npx @stoplight/spectral-cli lint openapi.yaml
shellcheck scripts/*.sh
npm run typecheck && npm run test:ts
sqlite3 -bail :memory: ".read sqlite/schema.sql"   # the app opens ${APP_DATA:-.}/app.db
```

The owner (`benpshore`) may push their own work directly to `main` without a PR or passing CI. CI still runs after a push; releases retain their CI gates. Force-push, deletion, and merge commits remain blocked for everyone.

Other accounts must use a squash PR with passing, up-to-date `ci`. Agents must use PRs and CI even when authenticated as the owner (see `AGENTS.md`). GitHub checks the pushing account, so enforcing a human/agent boundary requires separate credentials.

## RAM disk shell utility

The read-only macOS sizing prototype is `scripts/ramd SIZE --dry-run`. Examples:

```sh
scripts/ramd 2g --dry-run
scripts/ramd 512MB --dry-run
scripts/ramd --dry-run 2G
```

Size suffixes are case-insensitive. This implementation currently interprets `K`, `KB`, `KiB`, `M`, `MB`, `MiB`, `G`, `GB`, `GiB`, `T`, `TB`, and `TiB` as binary powers of 1024: `2g` is 2 GiB and `512MB` is 512 MiB. Ben's examples did not settle decimal versus binary units, so this is a documented implementation convention, not a confirmed interpretation. Sizes must be integral, at least 16 MiB, no larger than 1 TiB, and divisible into 512-byte sectors.

The dry run reads physical RAM with `sysctl -n hw.memsize`, page availability indicators with `vm_stat`, and the macOS memory pressure level with `sysctl -n kern.memorystatus_vm_pressure_level`. It plans only at normal pressure and when the request is at most one quarter of physical RAM and at most half the current free, inactive, and speculative page estimate. These are conservative point-in-time checks, not a memory reservation. The dry run prints the intended size, sectors, and filesystem plan; it never invokes attach, format, mount, detach, `diskutil`, or `ioreg` commands.

The shell process's dry-run path performs only argument parsing and the listed local reads and calculations. The mock suite puts fail-on-use shims first in `PATH` for common disk, filesystem, temporary-file, network, installer, and helper commands and asserts they are never called, including on malformed inputs and failed probes. This checks those named executable boundaries; it cannot prove the absence of every possible side effect by arbitrary programs, the shell/runtime, the operating system, or unrelated processes. No short flag alias is implemented while its spelling is pending selection.

The memory-pressure value is not a `0, 1, 2` ordinal. `sysctl -n` prints the value without its name; the Apple `libdispatch` header defines normal, warning, and critical as `0x01`, `0x02`, and `0x04`, respectively. Apple's `memory_pressure` utility source reads `kern.memorystatus_vm_pressure_level`; the prototype accepts only exact value `1` and refuses unknown values. See [`sysctl(8)`](https://www.manpagez.com/man/8/sysctl/), [Apple's libdispatch pressure definitions](https://github.com/apple-oss-distributions/libdispatch/blob/main/dispatch/source.h), and [Apple's `memory_pressure` source](https://github.com/apple-oss-distributions/system_cmds/blob/main/memory_pressure/memory_pressure.c).

Real provisioning is explicitly disabled. A path-based check followed by `diskutil eraseVolume ... /dev/diskN` or `hdiutil detach /dev/diskN` leaves an external detach/device-number-reuse race between the check and mutation; a per-user lock or another shell check cannot close it. The available `hdiutil(1)` manual copy documents `-drivekey` as setting a key/value on the device in the I/O Kit registry and documents `ram://` plus plist output, while Apple's [I/O Registry documentation](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/IOKitFundamentals/TheRegistry/TheRegistry.html) describes registry inspection with `ioreg`. These sources do not establish the current macOS output's exact token-to-BSD-device lineage. The `hdiutil` page consulted is a [macOS 13.6.5 man page copy](https://man.freebsd.org/cgi/man.cgi?manpath=macOS+13.6.5&query=hdiutil&sektion=1), not an Apple-hosted page. Exact `hdiutil` plist, `ioreg` association, and whole-disk `DiskUUID`/`VolumeUUID` availability for an unpartitioned HFS+ RAM disk remain unverified. No formatting or detachment path is included until those fields and safe target binding can be established.

The shell prototype does not create a device and therefore has no cleanup trap or stale lock. If a future implementation adds provisioning, it must account for process interruption and the external target-reuse race without claiming shell traps make the sequence atomic.

There is no Linux block-device backend; the command refuses Linux and does not substitute `tmpfs`. No diagnostic-mode flag or no-argument behavior has been defined yet; a bare invocation currently prints usage and exits. A non-dry-run invocation validates the size syntax, then exits with a clear disabled-provisioning error before invoking any disk or registry tool.

The mock-only suite is `sh tests/shell/test_ramd.sh`. It checks parsing and the read-only plan, verifies the disabled path invokes no device commands, and includes a cross-object token/BSD-name fixture that must not reach a mutation command. It performs no disk operations. Its captured output is in [`tests/shell/TEST-OUTPUT.txt`](tests/shell/TEST-OUTPUT.txt).
