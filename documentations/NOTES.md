# Implementation Notes & Cheat Sheet

This document provides **non-authoritative implementation reminders** intended
to reduce context switching during development.

This file is **advisory only**.  
In case of conflict, the following documents take precedence:

1. SystemArchitecture.md
2. DECISIONS.md (ADRs)
3. ASSUMPTIONS.md
4. THREATS.md
5. SCOPE.md

This document MUST NOT introduce new behavior, abstractions, or optimizations.

---

## 1. Constants (Advisory)

* **WAD**
  * `1e18`
  * Primary fixed-point scaling unit for all internal accounting.

* **RAY**
  * `1e27`
  * **Not used by default.**
  * MUST NOT be introduced unless explicitly authorized by a new ADR.

* **SECONDS_PER_YEAR**
  * `31_536_000`
  * Used only for interest rate normalization.

---

## 2. Opcode Reminders (Yul Semantics)

* **`TSTORE(slot, value)`**
  * Opcode: `0x5d`
  * Writes transient storage scoped to the current transaction only.

* **`TLOAD(slot)`**
  * Opcode: `0x5c`
  * Reads transient storage; value resets after transaction end.

* **`shl(shift, value)`**
  * Left-shift `value` by `shift` bits.
  * Equivalent to `value << shift`.
  * No overflow checks are performed.

* **`shr(shift, value)`**
  * Right-shift `value` by `shift` bits.
  * Equivalent to `value >> shift`.

**Reminder**
* Bitwise operations do **not** provide arithmetic safety.
* All inputs must already satisfy bounds defined in `ASSUMPTIONS.md`.

---

## 3. Storage Bitmasks (`UserConfig`)

### Slot Layout (256 bits total)

```text
[ User Debt (128 bits) ][ User Collateral (128 bits) ]
|                       |
<-- MSB               LSB