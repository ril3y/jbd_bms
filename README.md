# jbd_bms

Dart/Flutter library for talking to **JBD ("Xiaoxiang") smart BMS** boards over Bluetooth LE.
Many LiFePO4 batteries ship with a JBD-compatible BMS, including LOSSIGY packs.

Built on [`universal_ble`](https://pub.dev/packages/universal_ble), so it runs on
iOS, macOS, Windows, Android and Linux.

## Features

- Pack voltage, current, power, SOC, remaining/nominal capacity, temperatures
- Per-cell voltages, balancing state, FET (charge/discharge) state
- Live protection flags with readable labels
- Battery-life data: cycle count, production date, hardware/software version,
  lifetime protection-event counters, design vs. full-charge capacity
- Robust frame reassembly (length-based, checksum-validated) and serialized requests
- Pure-Dart protocol layer you can unit-test without hardware

## Usage

```dart
import 'package:jbd_bms/jbd_bms.dart';
import 'package:universal_ble/universal_ble.dart';

await JbdBmsClient.startScan();
final device = await UniversalBle.scanStream.first;
await JbdBmsClient.stopScan();

final bms = JbdBmsClient(device);
await bms.connect();

final health = await bms.readHealth();
print('${health.cycles} cycles, SOH ${health.stateOfHealth}');

bms.basicInfo.listen((i) => print('${i.voltage} V  ${i.current} A  ${i.soc}%'));
bms.cellVoltages.listen(print);
bms.startPolling();
```

### Platform setup

- **iOS / macOS:** add `NSBluetoothAlwaysUsageDescription` to `Info.plist`.
  On macOS also add the `com.apple.security.device.bluetooth` entitlement.
- **Windows:** Bluetooth 4.0+ adapter.

## Protocol

See [PROTOCOL.md](PROTOCOL.md) for the GATT layout, frame format and field offsets.

Read-only by design: the library sends only read commands, plus the factory-mode
enter/exit pair needed for register reads on older firmware. It never writes
configuration.

## License

MIT. Not affiliated with JBD or any battery manufacturer.
