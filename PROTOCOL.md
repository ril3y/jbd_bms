# LOSSIGY BMS BLE protocol (reverse engineered)

Source: `io.LSG.com` v1.1.3 (APKPure XAPK), base APK SHA-256
`bf4a9bad4b52b36c479c5483bb5aa0bf5187a6f61807949c8ca96e5e110d8e25`.
The app is a DCloud uni-app; all BLE logic is plain JS in
`assets/apps/H5FAAB933/www/app-service.js`, class `Bluetooth` (`utils/BLE.ts`), lines ~360–1242.

**Verdict: this is the stock JBD / "Xiaoxiang" smart BMS protocol.** Anything that speaks JBD
(e.g. Overkill Solar / `jbdtool` / esphome `jbd_bms`) should talk to this battery.

## GATT

| Role | UUID | Notes |
|---|---|---|
| Service | `0000FF00-0000-1000-8000-00805F9B34FB` | Scan is filtered on this service |
| Notify (read) | `0000FF01-0000-1000-8000-00805F9B34FB` | Enable notifications; responses arrive here |
| Write | `0000FF02-0000-1000-8000-00805F9B34FB` | App writes **without response**, in 20-byte chunks |

Connect timeout 10 s; the app waits 2 s after connect before using the link.

## Frame format

Request:  `DD  op  cmd  len  data[len]  chkH chkL  77`
Response: `DD  cmd status len  data[len]  chkH chkL  77`

- `op`: `A5` = read, `5A` = write
- `status`: `00` = OK
- Checksum = `(0x10000 - sum(bytes from cmd/status through end of data)) & 0xFFFF`, big-endian.
  Request sum covers `cmd, len, data`; response sum covers `status, len, data`.
- Notifications are split in ≤20-byte chunks. The app reassembles by "starts with DD, ends with 77",
  which is fragile (0x77 can appear in data). Better: total frame length = `len + 7`.
- All multi-byte values are **big-endian**.

## Commands used by the app

| Purpose | Bytes |
|---|---|
| Basic info (0x03) | `DD A5 03 00 FF FD 77` |
| Cell voltages (0x04) | `DD A5 04 00 FF FC 77` |
| Hardware version (0x05) | `DD A5 05 00 FF FB 77` |
| Protection counters (0xAA) | `DD A5 AA 00 FF 56 77` |
| Chip type (0x00) | `DD A5 00 00 00 00 77` |
| Enter factory mode | `DD 5A 00 02 56 78 FF 30 77` |
| Exit factory mode | `DD 5A 01 02 28 28 FF AD 77` |
| MOS control (0xE1) | `DD 5A E1 02 00 code chk chk 77`; code: 0=both on, 1=charge off, 2=discharge off, 3=both off |
| Read param block (0xFA) | `DD A5 FA 03 00 index count chk chk 77` (e.g. index 0xB0 count 4 = BMS model) |

**Polling (dashboard):** alternates 0x03 and 0x04 every 1 s (0x03, 0x04, 0x03, ...).

## 0x03 basic info response — offsets into the full frame

| Offset | Size | Field | Scale |
|---|---|---|---|
| 4 | u16 | Pack voltage | ×0.01 V |
| 6 | **s16** | Current (+ charge / − discharge) | ×0.01 A |
| 8 | u16 | Remaining capacity | ×0.01 Ah |
| 10 | u16 | Nominal/full capacity | ×0.01 Ah |
| 12 | u16 | Cycle count | |
| 14 | u16 | Production date | day = v&31, month = (v>>5)&15, year = 2000+(v>>9) |
| 16 | u16 | Balance status, cells 1–16 (bitmask) | |
| 18 | u16 | Balance status, cells 17–32 | (app ignores) |
| 20 | u16 | Protection flags (bitmask, 0 = OK) | see below |
| 22 | u8 | Software version (BCD-ish, `0x23` → "2.3") | |
| 23 | u8 | **SOC %** | |
| 24 | u8 | FET status: bit0 charge ON, bit1 discharge ON, bit3 heater | |
| 25 | u8 | Cell count | |
| 26 | u8 | NTC count `n` | |
| 27.. | u16 × n | Temperatures | (raw − 2731) / 10 → °C |

Derived values the app shows: power = V × I; time-to-full = (nominal − remaining)/I;
time-to-empty = remaining/|I|.

## Protection flag bits (0x03 offset 20)

The app only reports the index of the lowest set bit. The labels below are the standard JBD
mapping (inferred, not read from the LOSSIGY app's string table):

0 cell over-voltage · 1 cell under-voltage · 2 pack over-voltage · 3 pack under-voltage ·
4 charge over-temp · 5 charge under-temp · 6 discharge over-temp · 7 discharge under-temp ·
8 charge over-current · 9 discharge over-current · 10 short circuit · 11 front-end IC error ·
12 MOS software lock

## 0x04 cell voltages response

`len` bytes of u16 big-endian, one per cell, in **mV**. 12 cells → `len = 24`.

## Battery-life data

**There is no history/event log on the BMS.** The complete command set used by the stock
app is 0x00/0x01 (factory mode), 0x03, 0x04, 0x05, 0xA0, 0xA2, 0xAA, 0xFA (read/write),
0xE1 (MOS control), 0x0A (balance toggle) and `FF AA` (BLE name); none returns history.
Lifetime totals only: cycle count (0x03) and protection counters (0xAA).


**0xAA protection counters:** `len` bytes of u16 lifetime event counts. The stock app has
the read command but never calls or labels it. The library uses the standard JBD order
(**unverified on LOSSIGY hardware**):
short circuit, charge OC, discharge OC, cell OV, cell UV, charge OT, charge UT,
discharge OT, discharge UT, pack OV, pack UV.

**0xFA parameter read (newer firmware):** request `DD A5 FA 03 00 index count chk 77`;
response `DD FA 00 len 00 index count words[count] chk 77`. The stock app labels index 0
as nominal capacity and 112 as full-charge capacity (u16, ×10 mAh). Other indexes it reads:
2 (protect ×2), 8 (temp ×8), 16 (protect ×8), 24 (current ×2), 28 (sense resistor ×4),
34 / 106 (SOC-voltage curve), 38, 40, 44, 48, 52; string params 6 (serial), 56 (manufacturer),
88 (barcode), 158 (battery model), 176 (BMS model).

**Legacy registers (older firmware):** enter factory mode, then `DD A5 reg 00 chk 77` →
`DD reg 00 02 hi lo chk 77`, then exit factory mode. Standard JBD map: 0x10 design capacity,
0x11 cycle capacity, 0x17 cycle count (×10 mAh for capacities).

Firmware generation: the 0x03 response is "new" when `len > 22 + ntc*2 + 5`.

## Other

- `FF AA 06 ...` / `FF AA 07 len name... sum8` (on the same characteristic): read/set the BLE
  advertised name (8-bit sum checksum of `cmd + len + bytes`).
- Writes (`5A`) to config registers require entering factory mode first. **Don't write config
  params from your own app until you've read and backed up the existing values.**
