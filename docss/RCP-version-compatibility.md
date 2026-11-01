# NCS RCP ↔ OTBR-posix: OpenThread Revision Matching and RCP API Compatibility

*Investigation date: 2026-10-20. All SHAs below were checked with `git` against the official GitHub repositories.*

## Summary

- **No exact match exists.** No ot-br-posix commit, tag or branch pins the OpenThread commit used by the NCS RCP. That commit (`0fe68ff`) exists only in Nordic's downstream fork, so OTBR could never pin it.
- **Closest OTBR match:** `fbde28a059604f4206ed742e37b2fc0ea3134282` (ot-br-posix `main`, 2024-09-13). It pins upstream OpenThread `dccc519`, which is one commit after the RCP's upstream base `2aeb8b8`. That extra commit changes only simulation and example-platform code, which the OTBR build does not compile.
- **OTBR `v2026.10.0` with an NCS 3.4.1 RCP:** the RCP API version check passes in both directions. The two sides are not the same source, so validate the setup on hardware.

---

## A. NCS RCP OpenThread revision

| Item | Value |
|---|---|
| NCS releases pinning it | sdk-nrf `v3.4.0` (`99553055607b`), `v3.4.0-rc1/rc2`, `v3.4.1` (`b20f8619ba9a`), `v3.5.0-preview1…4`, `main`. (`v3.3.x` used `ncs-thread-reference-20250402`.) |
| Repository containing `0fe68ff` | `nrfconnect/sdk-openthread` (west project `openthread`, path `modules/lib/openthread`) |
| Meaning of `0fe68ff` | Tip of sdk-openthread `main`: *"[nrf noup] mbedtls: call mbedtls_ssl_set_hostname on setup"* (2026-05-22). This is a Nordic-only commit. |
| Full SHA | `0fe68ff23527e8bb9a9821ca96a255fccfbb44a7` |
| Upstream OpenThread base | `2aeb8b833ba760ec29d5f340dd1ce7bcb61c5d56`: *"[mle] prioritize equivalent pending dataset update over MLE announce (#10631)"* (2024-09-11) |
| Downstream delta | 37 linear Nordic commits and no merges. 12 are `[nrf noup]`: mbedTLS/PSA adaptations, TX-timestamp propagation and posix build fixes. 25 are `[nrf fromtree]`: later upstream fixes copied back, mostly `diag`, plus one `radio_spinel.cpp` fix (#10976) and some message/CLI/DNS changes. |

The short SHA `0fe68ff` does not exist in upstream `openthread/openthread`, `ot-br-posix` or `sdk-nrf`.

> **Caveat:** the manifest's `userdata.ncs.upstream-sha: c6eaeda5…` points to a 2023 commit. That value is out of date. The real upstream base comes from `git merge-base 0fe68ff upstream/main`, which gives `2aeb8b8`.

**Evidence**
- [sdk-nrf v3.4.0 west.yml](https://github.com/nrfconnect/sdk-nrf/blob/v3.4.0/west.yml)
- [sdk-openthread @ 0fe68ff](https://github.com/nrfconnect/sdk-openthread/commit/0fe68ff23527e8bb9a9821ca96a255fccfbb44a7)
- [Upstream base 2aeb8b8](https://github.com/openthread/openthread/commit/2aeb8b833ba760ec29d5f340dd1ce7bcb61c5d56)

## B. OTBR-posix candidates

OTBR pins OpenThread as a git submodule at `third_party/openthread/repo`. I read the pin with `git ls-tree` for all 1,158 commits on `main` that change it, and for every tag and branch. None of them pins `2aeb8b8`.

| OTBR-posix tag/release | OTBR commit | Pinned OpenThread SHA | Relationship to RCP base `2aeb8b8` | Exact match? |
|---|---|---|---|---|
| main, PR #2485 (2024-09-11) | `d5d79a87d248c10bbada0f5356b12dab59e321cd` | `c0690e78fcb0a780770687a70eac74858efe5d7c` | 2 commits older. Lacks the MLE/dataset change in `src/core` (#10631) and a CI change. | No |
| **main, PR #2490 (2024-09-13)** | **`fbde28a059604f4206ed742e37b2fc0ea3134282`** | **`dccc5193afd64cfe1b3488a1ed2107355d5eeabc`** | 1 commit newer (#10670). It only touches `examples/platforms/simulation` and `examples/platforms/utils`. `src/`, `include/` and `third_party/` are identical to the base. | No, but the same OpenThread code for an OTBR build |
| main, PR #2491 (2024-09-13) | `b9210e7ad987` | `97a3f7648faf…` | 2 commits newer (also adds TREL CLI #10702) | No |
| main, PR #2493 (2024-09-16) | `a3eff4d157b1` | `d7810fa04d46…` | 3 commits newer | No |
| `thread-reference-20250612` | `2f3c799c7463` | `baf13fc99455…` | Much newer | No |
| `v2026.06.0` … `v2026.10.0` | `c7164ef6d0f1` … `cb4bdae242b2` | `fa3213ec…` … `cb18e0f5…` | Far newer | No |

## C. Recommended OTBR-posix revision (closest source match)

- **Commit:** `fbde28a059604f4206ed742e37b2fc0ea3134282` (no release tag)
- **Pinned OpenThread:** `dccc5193afd64cfe1b3488a1ed2107355d5eeabc`
- **Exact match with the RCP?** No. Both sides share the same upstream base, but the RCP adds Nordic commits on top.
- **What differs:**
  1. **Upstream side:** one extra simulation-only commit, which OTBR does not compile. `git diff 2aeb8b8 dccc519 -- src include third_party` is empty.
  2. **Nordic side:** the RCP has 37 Nordic commits that OTBR lacks. The Spinel protocol and RCP API version are unchanged (see section E). On the RCP side:
     - The TX-timestamp flag in `radio.h` stays inside the RCP.
     - New `diag` sub-commands exist only on the RCP. An OTBR host from this era may not know them.
  3. **OTBR side:** OTBR lacks the host-side `radio_spinel.cpp` fix (#10976), which NCS copied back into its fork.
- **Confidence:** high, because the conclusions rest on full-history git checks. I did not build or run OTBR against the RCP. A September 2024 OTBR may need build fixes on a modern distro.

```bash
git clone https://github.com/openthread/ot-br-posix.git && cd ot-br-posix
git checkout fbde28a059604f4206ed742e37b2fc0ea3134282
git submodule update --init --recursive
# Optional: build OTBR against exactly the RCP's upstream base.
# For the code OTBR compiles this is identical to dccc519, but the
# result is a submodule pin that is not in upstream history.
git -C third_party/openthread/repo checkout 2aeb8b833ba760ec29d5f340dd1ce7bcb61c5d56
```

## D. Reproducibility

```bash
# 1. NCS pin and its upstream base
git clone https://github.com/nrfconnect/sdk-nrf
git -C sdk-nrf show v3.4.1:west.yml | grep -A8 'name: openthread'
git clone https://github.com/nrfconnect/sdk-openthread && cd sdk-openthread
git rev-parse 0fe68ff                     # -> 0fe68ff23527e8bb9a9821ca96a255fccfbb44a7
git remote add up https://github.com/openthread/openthread && git fetch up main
git merge-base 0fe68ff up/main            # -> 2aeb8b833ba760ec29d5f340dd1ce7bcb61c5d56
git log --oneline 2aeb8b833..0fe68ff      # 37 [nrf noup]/[nrf fromtree] commits

# 2. OTBR pin
git -C ../ot-br-posix ls-tree fbde28a059604f4206ed742e37b2fc0ea3134282 third_party/openthread/repo
#   -> 160000 commit dccc5193afd64cfe1b3488a1ed2107355d5eeabc

# 3. Compare (inside sdk-openthread, which now has upstream objects)
git merge-base --is-ancestor 2aeb8b833 dccc5193a && git log --oneline 2aeb8b833..dccc5193a   # 1 commit (#10670)
git diff --stat 2aeb8b833 dccc5193a -- src include third_party                                # empty
git diff 2aeb8b833 0fe68ff -- src/lib/spinel/spinel.h                                         # empty

# 4. Confirm no OTBR commit on any ref pins the base exactly
cd ../ot-br-posix && git log --all --format=%H -- third_party/openthread/repo | \
  while read c; do git ls-tree $c third_party/openthread/repo; done | grep 2aeb8b833   # no output
```

## E. RCP API compatibility: NCS 3.4.1 RCP with OTBR-posix v2026.10.0

`v2026.10.0` (`cb4bdae242b2`) pins upstream OpenThread `cb18e0f598059d733b3382b81437c4138195d1ea` (2026-09-25). NCS 3.4.1 pins sdk-openthread `0fe68ff`, the same revision as 3.4.0.

| `src/lib/spinel/spinel.h` | NCS 3.4.1 RCP (`0fe68ff`) | OTBR v2026.10.0 host (`cb18e0f`) |
|---|---|---|
| Spinel protocol | 4.3 | 4.3 |
| `SPINEL_RCP_API_VERSION` | 10 | 11 |
| `SPINEL_MIN_HOST_SUPPORTED_RCP_API_VERSION` | 4 | 4 |

**Version check:** at startup, `RadioSpinel::CheckRcpApiVersion()` in `src/lib/spinel/radio_spinel.cpp` checks compatibility in both directions:

- RCP API version 10 ≥ the host's minimum of 4 → passes
- Host API version 11 ≥ the RCP's minimum host version of 4 → passes

**Change from version 10 to 11:** a single commit, upstream `444d1dd6b` ([mle] alternate RLOC16, #10006). It adds `SPINEL_PROP_MAC_15_4_ALT_SADDR`. `RadioSpinel::SetAlternateShortAddress()` sends it only when the RCP advertises `OT_RADIO_CAPS_ALT_SHORT_ADDR`. The NCS RCP doesn't, so the host skips this feature instead of failing. The effect is a minor behaviour difference during role transitions, not a breakage.

**Required radio capabilities:** unchanged since the RCP's base. `kRequiredRadioCaps` in `src/posix/platform/radio.hpp` is still transmit security, transmit timing, ACK timeout, transmit retries and CSMA backoff.

**What the version check does not prove:**
- The host is about 2,100 upstream commits newer than the RCP's base. 47 of those commits touch `spinel.h` or `radio_spinel.cpp`. The API version only shows that the Spinel definitions are compatible, not that every runtime behaviour matches.
- I found no NCS 3.4.x documentation that names an OTBR revision to pair with this RCP.

**Hardware validation:** build OTBR with `OPENTHREAD_CONFIG_DIAG_ENABLE` and `OPENTHREAD_POSIX_CONFIG_RCP_CAPS_DIAG_ENABLE`, then run:

```
ot-ctl diag rcpcaps capflags
ot-ctl diag rcpcaps spinel
ot-ctl diag rcpcaps srcmatchtable
```

Also check the `otbr-agent` startup log for `incompatible API versions` or `missing required capabilities`. Finish with a form/join test and an SRP/border-routing test.

**Conclusion:** `v2026.10.0` should work with the NCS 3.4.1 RCP at the RCP API level, and it includes current host-side fixes. `fbde28a` remains the closest source match, which matters for certification or for reproducing a known-good setup.

## Zephyr version

Zephyr: both pins are plain upstream OpenThread commits on main.
* The 4.4 pin is about 1,300 commits newer than the NCS base,
* The 4.5 pin about 2,060.

OTBR: no ot-br-posix commit pins either Zephyr revision exactly.
* OTBR v2026.10.0 pins upstream OpenThread cb18e0f, which is 24 commits after the Zephyr 4.5 pin.
* OTBR v2026.09.0 is 37 commits before it.
## Building the NCS RCP against upstream OpenThread (experiment, 2026-10-31)

CI variant `rcp-holyiot-nrf52840-dongle-usb-legacyusb-otupstream` builds the same dongle firmware with plain
`openthread/openthread` instead of Nordic's `sdk-openthread` fork (west project `openthread`, replaced after
`west update` by a `git checkout` of the pinned SHA, matrix field `otup`).

Local build results on NCS v3.4.1 (nRF52840 dongle, legacy USB conf, FEM conf), all configure/compile/link only, **not run on hardware**:

| OpenThread revision | Result |
|---|---|
| `0fe68ff` (NCS fork, default) | builds, 127.9 KB |
| `cb18e0f` (OTBR v2026.10.0 pin) | builds, 133.4 KB, with two changes: (1) NCS's `nrf/` and `zephyr/` `modules/openthread/CMakeLists.txt` still set the removed options `OT_WAKEUP_COORDINATOR` / `OT_WAKEUP_END_DEVICE` (upstream errors on them), so they are renamed to `OT_WAKE_INITIATOR` / `OT_WAKE_LISTENER` (CI does this with `sed`); (2) `CONFIG_OPENTHREAD_PLATFORM_KEY_REF=y` ([boards/openthread-upstream.conf](../boards/openthread-upstream.conf)), since upstream's `crypto_platform_psa.cpp` requires key references when the crypto lib is PSA (Zephyr only selects them for non-RCP builds). |
| `e4d97681c` (the upstream commit Zephyr pins in this NCS) | builds, 128.3 KB, with only `CONFIG_MBEDTLS_ASN1_PARSE_C=y` added (needed by both upstream revisions; `nrf_security` leaves ASN.1 parsing off) |

The upstream build keeps `USB_DEVICE_STACK` + `USB_DEVICE_INITIALIZE_AT_BOOT`, `MPSL_FEM(_SIMPLE_GPIO)`, the FEM devicetree
node and `OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO` (reset to bootloader). The CI variant now uses `cb18e0f`, i.e. the same OpenThread source as OTBR-posix v2026.10.0 (the fork's base is from 2024-09). Still to test on the Pi:
`ot-ctl rcp version`, `diag rcpcaps`, Spinel reset to bootloader, stability on a Pi 3 with `otbr-agent` running.

### Result on hardware (Pi 3, OTBR 0.3.0-cb4bdae, 2026-11-01)

Plain `cb18e0f` + the two changes above runs and reports `OPENTHREAD/cb18e0f59`, but **all MAC-secured unicast TX aborted**
(`TxErrAbort`, about 90 %), so the node dropped out of the mesh and CoAP data stopped. Usable only with the patch below.

Cause, found by printing the nRF 802.15.4 driver's TX error and the key calls over the USB console:

- The driver reported `NRF_802154_TX_ERROR_KEY_ID_INVALID` (8). The NCS glue maps every unknown TX error to `OT_ERROR_ABORT`, which hid it.
- Upstream now passes a plain key ID mode (the RCP sends `1`) to `otPlatRadioSetMacKey()`, and documents it as "must be ignored by the radio platform".
  NCS's `radio_nrf5.c` does `aKeyIdMode >> 3`, gets 0, treats the call as "clear all keys" and never stores them. The driver then has no key for any secured frame.
- Upstream can also pass an unset prev/next key reference, so `otPlatCryptoExportKey()` fails for it (the `__ASSERT` fired in a build with asserts on).

That first patch (key mode + fallback) was **not enough**: TX was acked at link level, but the peer router never answered (ping 0/N, `RxErrSec` rising)
because its MIC check failed on every secured frame. Two more causes, found by printing the key references, export errors and the PSA import status over the USB console:

- **PSA key slots.** With `CONFIG_OPENTHREAD_PLATFORM_KEY_REF=y` the RCP's SubMac keeps its prev/curr/next MAC keys as PSA keys (3 slots).
  NCS sets `CONFIG_MBEDTLS_PSA_KEY_SLOT_COUNT=1` for RCP builds (the fork RCP uses literal keys), so two of three `psa_import_key()` calls returned `-141` (insufficient memory).
  `SuccessOrAssert` is a no-op without asserts, the reference stayed 0, the export failed and the radio was given an all-zero key.
- **In-place export.** `otMacKeyMaterial.mKeyMaterial` is a union of the key reference and the literal key. The NCS code exported the key *into* that union, overwriting the reference,
  so SubMac's later `DestroyKey()` freed nothing and leaked a slot on every key update.

Fix (applied by the CI `otup` step): [patches/ncs-radio_nrf5-upstream-openthread.patch](../patches/ncs-radio_nrf5-upstream-openthread.patch) (key index 0 clears, otherwise mode 1;
export into local buffers; prev/next fall back to the current key if their reference can't be exported) plus `CONFIG_MBEDTLS_PSA_KEY_SLOT_COUNT=4` in `boards/openthread-upstream.conf`.
With both: ping to the leader 4/4 and 6/6 (12–15 ms), `RxErrSec` 0, secured frames received from the peer, RCP and OTBR on the same OpenThread revision.
Not yet verified: a long soak, `diag rcpcaps`, the CI build, and the module/MCUboot flow.

Debug technique (no debugger needed): `printk()` on the USB CDC console shares the Spinel port. Run `otbr-agent` under `strace -f -e trace=read -s 2000` and grep the raw bytes for your marker.
Attach strace before the agent starts, because the keys are set during init.

Also tried: Zephyr's own coprocessor sample (Zephyr platform layer, no `radio_nrf5.c`) against `cb18e0f`. It builds and runs but showed the same aborts, so that platform layer needs an equivalent fix and was not pursued
(branch `zephyr-upstream-rcp`).
