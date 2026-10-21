## 0.2.0

* History building blocks (the BMS itself keeps no log): `BmsSample`,
  `SessionTracker` (charge/discharge sessions with Ah, Wh, SOC, peak current,
  temperature, cell spread), `EventDetector` (cycle increments, protection
  flags raised/cleared, protection-counter deltas), all JSON-serializable.

## 0.1.0

* Initial release: JBD BMS frame building, chunk reassembly, checksum validation.
* Parsers for basic info (0x03), cell voltages (0x04), hardware version (0x05),
  protection counters (0xAA), 0xFA parameters and legacy registers.
* `JbdBmsClient` on `universal_ble` with serialized requests, polling and `readHealth()`.
