# Architecture — Garmin_BLE_data_transfer

> How the system is built and what every file does. The binary format is in
> [protocol.md](protocol.md); building, loading and verifying in [guide.md](guide.md);
> the firmware in detail in [esp32/README.md](../esp32/README.md).

- **Central**: FR255 (Monkey C, min API 5.2.0). The data fields (v3, v4) read the sensors
  in `compute(info)` (~1 Hz); the Monitor (v5) is a device app with its own Timer. They
  sample and **write** the chunks to the DATA GATT characteristic.
- **Peripheral**: ESP32-CAM on a power bank (ESP-IDF v5.5, NimBLE). It receives the
  chunks, **reassembles** them, applies the **integrity checks**, prints on the console
  and logs to microSD.

The watch recognises the peripheral by the Service UUID (v3) or by the Manufacturer
Specific Data of the advertising (v4, v5).

---

## Architecture

```
┌───────────────────────────────────────────────┐   BLE (v3 chunks)  ┌──────────────────────────────┐
│                 Garmin FR255                   │  ───────────────►  │        ESP32-CAM (NimBLE)     │
│                                                │                    │                               │
│  Sensors (Activity.Info, SystemStats)          │                    │  ble.c — GATT server          │
│    │                                           │                    │   • reassembles the chunks    │
│    ▼   every 5 s: Sampler → 12 values          │  write DATA        │   • integrity checks          │
│  V3DfView  (strategy = Variant.ID)             │  (HEADER 4B +      │   • FULL/DELTA/BATCH parser   │
│    ├─ FULL / DELTA / BATCH → Encoders          │   PAYLOAD ≤16B)    │   • prints a CSV row          │
│    ├─ Chunker: payload → chunks                │ ─────────────────► │                               │
│    ├─ BleManager: chunk queue (1 write in      │                    │  sd.c — 5 s task              │
│    │  flight)                                  │                    │   • activity_N.csv per        │
│    └─ FitLogger: dev_battery / dev_variant     │  re-advertising    │     activity (60 s timeout)   │
│         → into the FIT of the activity         │  on disconnection  │                               │
└───────────────────────────────────────────────┘                    └──────────────────────────────┘
        │                                                                (optional SD, hot-plug)
        ▼
   FIT of the activity (GARMIN\ACTIVITY\*.fit)
   with the battery + variant developer fields
```

### v4 architecture (MULTI variant)

```
                          advertising: Service UUID + MSD "T4" node_id busy
                 ┌──────────────────────────────────────────────────────────┐
                 ▼                          ▼                               ▼
          ESP32 edge 1               ESP32 edge 2                    ESP32 edge 3
       (free: connectable)     (connected: busy, NON-conn.)     (free: connectable)
                 ▲                          ▲                               ▲
                 └────────── scan ──────────┼─────────── scan ──────────────┘
                                            │ write DATA (4 chunks/sample)
                                            │ ACK = write response of last chunk
                              ┌─────────────┴──────────────┐
                              │ Garmin FR255 — BLE-Multi    │
                              │  Sampler → SampleRing (1 h) │
                              │  EdgeRadar: RSSI, handoff   │
                              │  MultiManager: 1 connection │
                              └─────────────────────────────┘

  Every edge writes multi_<session>_n<node>.csv; at the end of the activity
  tools/merge_multi.py rebuilds the single stream (dedup by seq, gaps, handoffs).
```

---

## File-by-file description

### Garmin side — `source/`

- **`ProtocolV3.mc`** — `ProtoV3` module: protocol v3, i.e. the constants of the
  transport header (shifts/masks), the formats (`FMT_FULL/DELTA/BATCH` and `FMT_APP` for
  v4 and v5), the 12 fields, the encoding offsets, the sentinel, `packHeader()`, and the
  **CRCs** (per-nibble CRC-16, CRC-8) used by v4 and v5. Mirror of
  `esp32/main/include/protocol_v3.h`: the two files carry the same tables as
  [protocol.md](protocol.md), the specification of the binary format.
- **`Config.mc`** — tunable parameters: `SAMPLE_EVERY` (5 ticks ≈ 5 s), `BATCH_SAMPLES`
  (6), the **DELTA thresholds** `TH_*` (in the raw unit already encoded: e.g.
  `TH_BATTERY = 50` = ±0.5 %). For the MULTI (`MULTI_*`, also used by the Monitor):
  - the accepted edges (`MULTI_NODE_MIN..MAX` = 1–10);
  - rate (5 s), samples per packet (4) and queue capacity (720);
  - edge choice: 1.5 s window, 10 s pairing timeout and cool-down;
  - RSSI filter: alpha 0.3, 5 s validity, current edge "gone" after 8 s;
  - handoff: 8 dB hysteresis, 3 votes, 15 s minimum stay;
  - roaming scan always on;
  - 6 s write timeout and 3 failures before abandoning the edge;
  - period of the diagnostic log (10 s).
- **`Sampler.mc`** — reads the 12 values from `Activity.Info` and
  `System.getSystemStats()`, applies offsets/fixed-point and replaces the `null` fields
  with the sentinel.
- **`Encoders.mc`** — builds the payloads of the three formats and computes the DELTA
  bitmask (bit set if `|value − last sent| ≥ threshold`; the timestamp bits 8/10/11
  always set).
- **`Chunker.mc`** — splits the payload into chunks (`HEADER 4 B + ≤16 B`),
  `cnt = ceil(len/16)`, 4 fields per full chunk, no field split, last chunk possibly
  short.
- **`BleManager.mc`** — scan by Service UUID, connection, and **chunk queue**:
  `sendPacket()` queues the chunks of a packet; chunk N+1 leaves only after the outcome
  (`onCharacteristicWrite`) of chunk N (`writeInProgress` flag). On-screen diagnostics:
  `lastChunkCount` = chunks of the **last** packet (FULL = always 3), `totalChunks` =
  **cumulative** chunks of the recording: reset at the activity **start** (from
  OFF/STOPPED; resuming from pause does NOT reset it), so at the end of the activity
  `total` = total radio cost of the session.
- **`MyBleDelegate.mc`** — BLE callbacks (scan, connection, write outcome) that move the
  queue forward.
- **`FitLogger.mc`** — creates two developer fields in the FIT: `battery` (id 0, FLOAT,
  RECORD, written at every `compute()`) and `variant` (id 1, UINT8, SESSION, written once
  = `Variant.ID`). See [§ FIT Contributor](#fit-contributor-data-fields). Annotated
  `(:datafield)`: the Monitor build excludes it (see § Per variant).
- **`V3DfView.mc`** — the data field of variants 1-3: `compute(info)` counts the ticks
  and every 5 it samples and sends according to `Variant.ID`. For all of them this
  happens **only with the timer running** (`Activity.Info.timerState ==
  TIMER_STATE_ON`): before the start, in pause and after the stop nothing is sampled or
  sent. It writes the battery in the FIT at every compute; `onUpdate` draws with an
  **adaptive layout** (full screen / top half) the variant name, HR, the `chunk` count
  of the last packet with the **cumulative total right below** (`total`), and the BLE
  state.
- **`DataFieldApp.mc`** — entry point of the data fields: creates the `BleManager`
  (variants 1-3) or the `MultiManager` (variant 5), starts BLE, shows the matching view.
- **`ProtocolV4.mc`** — v4: header offsets, `buildPacket()` (header + samples already
  serialised + CRC-16 BE), `parseAdv()` of the Manufacturer Specific Data. Mirror of
  `esp32/main/include/protocol_v4.h`.
- **`SampleRing.mc`** — v4: preallocated ring buffer (720 × 48 B) with contiguous seqs;
  serialises when sampling, removes by seq on confirmation, drops the oldest on
  overflow.
- **`EdgeRadar.mc`** — v4: filtered RSSI of every registered edge and the choice and
  handoff **policy** (minimum stay, hysteresis, votes, cool-down). No BLE call: time is
  a parameter, so it can be tested with synthetic times.
- **`MultiManager.mc`** — v4: SCAN / CONNECTING / CONNECTED states, a single paired
  device at a time, writes **with response**, retransmission, write timeout, roaming
  scan, handoff at the end of a packet. It also keeps the **radio telemetry** (time per
  state, scan time, attempts, chunks, failures): the times are accumulated at every tick
  **and at every state change**, so no stretch ends up in the wrong state. In `addSample`
  the telemetry replaces fields 4–7 of the sample, at the same instant as the battery. It
  also writes the diagnostic log (see guide § 6).
- **`MultiBleDelegate.mc`** / **`MultiDfView.mc`** — v4: BLE callbacks and screen. The
  screen shows:
  - the current edge "E<n>", with the "E" in a text font aligned to the baseline of the
    big number;
  - RSSI, queue, `conn`, delivered, handoffs / lost links, `compute()` peak;
  - the state on two lines ("● Connected" / "N seen"), with the dot **drawn**, because
    the FR255 fonts do not have ● ○.

  18 px texts on a full screen, 13 px on half a screen (where the state fits on one
  line). Details in guide § 6.
- **`Colors.mc`** — palette and colour per variant (Full green, Delta orange, Batch light
  blue, Multi yellow).

### Monitor (v5) — `source-monitor/`

The device app. The session is the open app: it opens at start-up and closes on exit.
- `MonitorApp`: 1 s Timer, session, sensors, a sample every 5 s, sound and vibration
  according to the alert mode.
- `MonitorManager` (derived from `MultiManager`): radio, delivery of the v5 packets with
  the `MonRing` queue, alert subscription.
- `AlertQueue`, `AlertView`: alerts to be confirmed and their screen.
- `MonitorView`, `MonitorDelegate`: main screen in four zones and keys (UP/DOWN change
  the alert mode, BACK exits).
- `MonitorSampler`, `ProtocolV5`, `MonDraw`, `MonCfg`: the 4 values, the v5 format, the
  text fitted inside the round screen, the parameters.

Description in [v5_monitoring.md § Code](v5_monitoring.md#code).

### Per variant — `variants/<name>/`

Every folder (`full`, `delta`, `batch`, `multi`, `monitor`) contains the build
**jungle**, the **manifest** (distinct app UUID, `fr255` device, permissions:
`FitContributor` for the data fields, `Sensor` for the Monitor) and **`VariantConfig.mc`**
with `Variant.ID` (1/2/3/5/6) and `Variant.NAME` ("FULL"/"DELTA"/"BATCH"/"MULTI"/
"MONITOR"). For the data fields it is the only difference between the builds. The Monitor
also has `source-monitor/` and `resources-monitor/`; in addition its jungle excludes the
parts of `source/` annotated `(:datafield)`, i.e. everything only the data fields need:
`DataFieldApp`, the two views, `FitLogger`, the v3 radio (`BleManager`, `MyBleDelegate`)
and the v4 one (`MultiManager`, `MultiBleDelegate`), `Sampler`, `Encoders`, `SampleRing`
and `Colors`. From `resources/` it takes only `drawables/`. This way it does not need the
`FitContributor` permission, does not carry the labels of the FIT fields, and its `.prg`
is a little lighter (about 133 kB against the 135 kB of the data fields).

`Variant.ID == 5` makes `DataFieldApp` create the `MultiManager` and the `MultiDfView`
instead of `BleManager` and `V3DfView`: variants 1-3 do not even instantiate the v4
classes.

### Resources — `resources/`

- **`strings/strings.xml`** — app names (`BLE-Full/Delta/Batch/Multi`) and the labels of
  the FIT fields (`Watch Battery`, `%`, `Var`…). The Monitor name is in
  `resources-monitor/`.
- **`drawables/`** — the app icon.
- **`fit/fitcontributions.xml`** — display metadata of the developer fields for Garmin
  Connect: `battery` (id 0) with `displayInChart="true"`, `variant` (id 1) with
  `displayInChart="false"`. ⚠️ Garmin Connect applies these metadata **only to apps
  published on the Store** (see [§ FIT Contributor](#fit-contributor-data-fields)).

### ESP32 side — `esp32/main/`

- **`main.c`** — initialises NVS and starts the two modules: `ble_init()` and
  `sd_logger_start()`.
- **`src/ble.c`** — GATT server: receives the chunks on the DATA characteristic,
  reassembles them by `pktId` (positional copy at `idx×16`), applies the integrity checks,
  picks the parser from the `flags` field and **prints a CSV row** on the console for every
  rebuilt sample. For `flags = APP` the `proto_ver` byte picks the protocol
  (`v5_route_monitor()`): `0x06` → v5, any other value → v4, which accepts only `0x05`
  and rejects the rest with an ATT error.
  - **v4**: v4 parser (`multi.c`); the outcome of the write of the last chunk is the
    **ACK** of the packet (ATT error if invalid or if the SD queue is full → the watch
    retransmits). The telemetry of fields 4–7 is split with `v4_tel_decode()` and ends
    up on SD in separate columns (`t_conn_s` … `coda`).
  - **v5**: v5 parser (`monitor.c`), with the same ACK as v4; a confirmations-only packet
    (`n_samples = 0`) is always confirmed and writes no rows. In addition the **ALERT**
    characteristic (NOTIFY), the subscription flag and the sending of the simulated
    alerts (`THIS_EDGE_EVENT_S`, `THIS_EDGE_EVENT_ALERT`). `ev_ack` and `ev_user` are only
    printed, because the edge does not retransmit the alerts
    ([v5_monitoring.md](v5_monitoring.md)).

  The advertising carries the node ID and stays active **while connected too**
  (non-connectable, busy bit), so the watch measures the RSSI of the current edge. It
  also contains the timer of the **pass-by simulation**: with `THIS_EDGE_OFF_S` > 0 the
  edge alternates visible and invisible phases, closing the connection at the start of
  every off phase (`sim_off`/`sim_on` events, `0x216` disconnection).
- **`src/multi.c`** — v4: parsing and validation (length → magic/version →
  `n_samples` → exact length → CRC16), and **per-node** continuity: duplicates (lost
  write response) and forward jumps (samples gone to another edge).
- **`src/multi_log.c`** — v4: `multi_<session>_n<node>.csv` (append, one row per sample,
  `dup` column) and `edge_n<node>_events.csv`, the event file of the edge, which also
  collects the v5 events (same names, told apart by the session).
- **`src/monitor.c`** — v5: parsing and validation in the same order as v4, and
  per-node continuity with a state separate from the v4 one.
- **`src/monitor_log.c`** — v5: `monitor_<session>_n<node>.csv` (append, one row per
  sample, `dup` column).
- **`THIS_EDGE_*` in `src/ble.c`** — the lines that differ between the firmware of the
  edges (fleet table in the comment above them): node ID, presence of the microSD,
  duration of the phases of the pass-by simulation (`OFF_S 0` = off) and simulated v5
  alerts (`EVENT_S 0` = none). They are changed by hand before `idf.py flash`.
  With `THIS_EDGE_HAS_SD 0` the mount is never attempted, the queues towards the SD are
  drained and discarded, and a valid v4 packet is always confirmed (never rejected for a
  full queue).
- **`src/sd.c`** — FreeRTOS task on core 1: every 5 s it **drains the queues** of the BLE
  module (v3 samples, v4 data and events, v5 data). For v3 it appends **one CSV row per
  sample** to the **activity** file `activity_N.csv` (opened at the first sample ≈
  start, first free index, closed after **60 s without samples**, not on disconnection).
  Empty queue = no rows (pre-start/pause/stop). Non-blocking, hot-plug SD, slot in
  **1-bit SDMMC** (CLK=GPIO14, CMD=GPIO15, D0=GPIO2) to coexist with the camera.
- **`include/config.h`** — `EDGE_NODE_ID` (the value defined in `ble.c`, for the other
  modules), `SD_MOUNT_POINT`, `SD_LOG_PREFIX`, `SD_LOG_PERIOD_MS`,
  `SD_ACTIVITY_TIMEOUT_MS`, `SD_TASK_CORE` (core of the SD task), the v4 queues
  (`MULTI_QUEUE_LEN`, `MULTI_EVENT_QUEUE_LEN`) and the v5 one (`MONITOR_QUEUE_LEN`).
- **`include/protocol_v3.h`** — mirror of `ProtocolV3.mc`: transport, FULL/DELTA/BATCH
  formats and CRC.
- **`include/protocol_v4.h`** — mirror of `ProtocolV4.mc`: v4 header offsets, layout of
  the Manufacturer Specific Data, `v4_build_adv()`. Reuses `be32_read` and the CRC-16 of
  `protocol_v3.h`.
- **`include/protocol_v5.h`** — mirror of `ProtocolV5.mc`: the 20-byte alert and its
  builder, the `v5_route_monitor()` routing and the offsets of the v5 uplink.
- **`include/monitor.h`** / **`include/monitor_log.h`** — v5: parsed packet, per-node
  continuity, record handed to the SD task.
- **`include/multi.h`** / **`include/multi_log.h`** — v4: parsed packet
  (`multi_pkt_t`), outcome of the per-node continuity (`multi_track_t`), records and
  events handed to the SD task.

### Tools — `tools/`

- **`build.ps1`** — builds one, several or all the variants into `bin/<variant>.prg` for
  the watch; the VS Code *Build* task runs it. It contains no machine paths: the SDK is
  the one active in the SDK Manager, Java and key come from the user settings
  `monkeyC.javaPath` / `monkeyC.developerKeyPath` (or from `JAVA_HOME`, the PATH and
  `~/.garmin/developer_key`). The variants are the `variants/<name>/` folders with
  `<name>.jungle`.
- **`check_header.py`** — generates the test vectors of the v3 transport header
  (`header_vectors.h`) and self-checks; they feed the C symmetry test.
- **`check_v4.py`** — generates the vectors of protocol v4 (`v4_vectors.h`): packets
  with sentinels and limit values, the advertising payload, and the check that the
  advertising fits in 31 bytes. It contains an **independent implementation** of the
  format, written from the offset table only and with bitwise CRCs instead of per-nibble
  ones: it is the reference the firmware is compared against, not a copy of its code.
- **`check_v5.py`** — the same for v5 (`v5_vectors.h`): uplink, encoding of the 4
  values, valid alerts and alerts to discard.
- **`merge_multi.py`** — v4 and v5: merges the `multi_<session>_n<node>.csv` (v4) or the
  `monitor_<session>_n<node>.csv` (v5) of all the edges, deduplicates by `seq`, checks
  that the copies match, splits the gaps into "to edges without files" (a `conn_no` is
  missing: edge without SD) and **lost** (real loss), and reports the samples left on the
  watch and the edge sequence; it summarises the events. Then, for v4, **battery and
  radio** from the first to the last sample (two rows are enough, thanks to the
  cumulative telemetry); for v5 the **session values** (duration, heart rate, battery
  drop, steps, altitude). Usage: `python tools/merge_multi.py <folder> --out session.csv`.

---

## FIT Contributor (data fields)

Every data field writes two developer fields into the FIT of the activity, with **the same
field IDs and names** everywhere (`source/FitLogger.mc`; display metadata in
`resources/fit/fitcontributions.xml`, `FitContributor` permission in the manifests of the
data fields). The Monitor does not write to the FIT:

| Field | Field ID | Type | Message | When | Value |
|---|:---:|---|---|---|---|
| `battery` | 0 | FLOAT (`%`) | RECORD | at every `compute()` | `System.getSystemStats().battery` |
| `variant` | 1 | UINT8 | SESSION | once per session | `Variant.ID` (1, 2, 3, 5) |

**Check**: a FIT reader must list `dev_battery` (N values) and `dev_variant`
(1=Full / 2=Delta / 3=Batch / 5=Multi); any tool that shows the developer fields of a
FIT file will do.

**Display on Garmin Connect**:

- The fields are always written in the FIT.
- The **"Watch Battery" chart on Garmin Connect does NOT appear** for sideloaded apps:
  Garmin Connect applies the `fitcontributions.xml` style (title, colour,
  `displayInChart`) **only to apps published on the Connect IQ Store**. There is no way to
  add a developer chart by hand on the website.
- The FIT must be taken **raw** from the watch (`GARMIN\ACTIVITY\`). Beware: the
  "TCX/GPX" exports from Garmin Connect **remove** the developer fields (use "Export
  Original" or, better, the file over USB).

---

## Technical notes

- **A single DATA characteristic + chunking**: 12 characteristics would mean 12
  serialised writes per cycle → an almost constant radio cost that would void the
  experiment. With 1 characteristic the number of on-air writes reflects the strategy
  (FULL=3, DELTA=1–3, BATCH=18/30 s) and becomes the measured variable. (Outside the
  experiment: MULTI=4 per sample, 13 per 4 samples while draining the queue; MONITOR=2
  per sample.)
- **Chunk queue**: ATT does not allow concurrent writes; `writeInProgress` serialises
  them.
- **Header symmetry**: building (Monkey C) and decoding (C) with explicit shifts/masks
  only, never C bitfields; the C side is checked by the vectors of `check_header.py`.
- **128-bit UUIDs in Monkey C**: built from two 32-bit Longs with shifts.
- **Data fields**: `compute()` (and therefore BLE and FIT writing) is active **only during
  a started activity** with the data field on a data screen.
- **One `.prg` per app**: the tasks build for the watch (`-d fr255`). With SDK 8.4.1 the
  `fr255_sim` target gives an identical binary (the SDK devices include only `fr255`), so
  the same file would also run in the simulator.
- **Write type**: the Connect IQ documentation describes `WRITE_TYPE_DEFAULT` (the one
  used by `requestWrite(chunk, {})`) as a **write without response**. Variants 1–3 use
  `{}`; the MULTI and the Monitor pass `WRITE_TYPE_WITH_RESPONSE` explicitly, because for
  them the outcome of the write is the ACK. In variants 1–3 `onCharacteristicWrite`
  therefore signals that the chunk was sent, not that it was received: delivery is not
  guaranteed for v3. The on-air behaviour has not been checked with a sniffer.
- **Null check on every access** to Activity.Info → sentinel if missing.
- **`float`, never `double` on the ESP32**: the LX6 FPU is single precision and every
  `double` is emulated in software. The `main` component builds with
  `-Wdouble-promotion`; the `double` casts in the `printf` calls are **explicit**
  because standard C promotes varargs anyway, and writing them keeps the warning useful
  where it matters, i.e. in the computation code.
- **Separate cores**: NimBLE on core 0, the parsing/SD task pinned to core 1
  (`xTaskCreatePinnedToCore`), so a slow FAT write never delays the radio.
- **Tolerant `registerProfile`**: if the system has run out of profile slots (it happens
  when restarting the app several times in the same process, for example in the
  simulator) the exception is absorbed — the profile with those UUIDs is already
  registered and still valid. Letting it propagate would kill the data field, and with it
  the recording of the activity, for a problem that does not prevent communication.
