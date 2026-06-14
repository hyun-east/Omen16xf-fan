# OMEN 16-xf Fan Control for Linux (board 8BCA)

EC-based fan control for the **HP OMEN 16-xf0052AX** (AMD Advantage variant, motherboard **8BCA**) on Linux.

On this model the standard `hp-wmi` fan interface does **not** work: the firmware ships broken WMI methods (`WMAA`, `WHCM`, `GTPS` all abort with `AE_AML_OPERAND_VALUE` / `CreateField of length zero`), so `pwm1` is never created and the upstream Linux 6.20+ fan-control patch has nothing to talk to. The firmware's own fan curve is extremely lazy — it lets the CPU sit at ~100 °C before spinning the fans up.

This project bypasses WMI entirely and writes the fan speed **directly to the Embedded Controller (EC)**, with a temperature curve, a keep-alive loop (the firmware reclaims fan control after a timeout), and a 90 °C emergency override.

> **Tested on:** HP OMEN 16-xf0052AX · Ryzen 7840hs + RTX 4060 labtop, · Ubuntu 22.04.5 · kernel 6.8.0-124-generic

---

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK.** This writes directly to your laptop's Embedded Controller. Wrong offsets on a *different* model can touch charging/power registers. The offsets here were found by observation on board **8BCA** and are **not guaranteed** for any other board. Verify your board ID before using (see below). The author and contributors are not responsible for any damage.

---

## Is this for you?

Check your board ID:

```bash
sudo dmidecode -s baseboard-product-name
sudo dmidecode -s system-product-name
```

This is built for **`8BCA`** / `OMEN by HP Gaming Laptop 16-xf0052AX`.

If your board differs, the EC fan offsets are very likely different — do **not** blindly run this. See [Finding your own offsets](#finding-your-own-offsets).

---

## EC register map (board 8BCA)

Found by diffing `ec_sys` dumps under load:

| Offset | seek (dec) | Meaning                         | Range            |
|--------|-----------|----------------------------------|------------------|
| `0xB0` | 176       | CPU temperature (°C)             | int °C           |
| `0xB2` | 178       | Fan 1 speed (write)              | 0 – 0x90 (sat.)  |
| `0xB4` | 180       | Fan 2 speed (write)              | 0 – 0x90 (sat.)  |

Notes:
- `0x90` (144) appears to be the saturation point — `0xFF` is written in the emergency path for margin but behaves the same as `0x90` in testing.
- The firmware periodically overwrites `0xB2`/`0xB4`, so a keep-alive rewrite (every loop) is required to hold a manual value.
- `0xA7` also tracks load (likely a secondary thermal/load metric) but is not used here.

> ⚠️ These offsets differ from the commonly cited `alou-S/omen-fan` `probes.md` map (which targets the 16-c0140AX / 5800H). On 8BCA, `0x95` falls inside a product-ID string, **not** a performance register — do not write to it.

---

## Installation

### 1. Dependencies

```bash
sudo apt install lm-sensors
```

### 2. Load `ec_sys` with write support at boot

```bash
echo 'ec_sys' | sudo tee /etc/modules-load.d/ec_sys.conf
echo 'options ec_sys write_support=1' | sudo tee /etc/modprobe.d/ec_sys.conf
```

### 3. Install the control script

Save [`omen-fan-control.sh`](omen-fan-control.sh) to `/usr/local/bin/` and make it executable:

```bash
sudo cp omen-fan-control.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/omen-fan-control.sh
```

### 4. Install the systemd service

Save [`omen-fan.service`](omen-fan.service) to `/etc/systemd/system/`, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now omen-fan.service
```

### 5. Verify

```bash
systemctl status omen-fan.service     # should be: active (running)
```

Run a load and watch the curve respond:

```bash
# terminal 1 — watch EC temp (0xB0) and fan bytes (0xB2/0xB4)
watch -n 1 'sudo xxd /sys/kernel/debug/ec/ec0/io | sed -n "12p"'

# terminal 2 — stress
sudo apt install stress-ng
stress-ng --cpu 0 --timeout 120s
```

You should hear the fans ramp as temperature climbs, and the `0xB2`/`0xB4` bytes should rise with the curve, hitting `ff` above 90 °C.

---

## Tuning the curve

Edit the curve arrays at the top of `/usr/local/bin/omen-fan-control.sh`:

```bash
# vertices (temp °C : fan value 0-144), ascending; linearly interpolated between points
CURVE_TEMPS=(40 55 70 85)
CURVE_FANS=( 24 60 100 144)
```

- Fan values range `0x18` (24, quiet minimum — fans never fully stop) to `0x90` (144, saturation).
- `EMERGENCY=90` forces `0xFF` at/above 90 °C regardless of the curve.
- Lower the temps for a more aggressive (cooler, louder) profile; raise them for quieter.

After editing:

```bash
sudo systemctl restart omen-fan.service
```

---

## Managing the service

```bash
sudo systemctl stop omen-fan        # hand control back to firmware
sudo systemctl start omen-fan
sudo systemctl disable omen-fan     # remove from boot
journalctl -u omen-fan -f           # live log
```

Stopping the service simply stops the keep-alive; the firmware reclaims automatic fan control within a couple of seconds, so there is no risk of the fans being left off.

---

## Finding your own offsets

If you have a different OMEN board, find your fan registers by observation (do **not** guess-write):

```bash
sudo modprobe -r ec_sys; sudo modprobe ec_sys write_support=1

# diff loop — prints only EC bytes that changed each second
while true; do
  sudo cat /sys/kernel/debug/ec/ec0/io > /tmp/ec_now.bin
  if [ -f /tmp/ec_prev.bin ]; then
    cmp -l /tmp/ec_prev.bin /tmp/ec_now.bin 2>/dev/null | while read pos old new; do
      printf "0x%02X: %d -> %d\n" $((pos-1)) "$old" "$new"
    done
  fi
  cp /tmp/ec_now.bin /tmp/ec_prev.bin
  sleep 1
done
```

Run `stress-ng --cpu 0` in another terminal and watch:
- The byte that climbs steadily with load = **CPU temperature**.
- A byte that steps up *as the fans audibly spin up* = **fan speed**.

Back up first (`sudo cp /sys/kernel/debug/ec/ec0/io /tmp/ec_backup.bin`), then test a candidate offset by writing a large value and listening:

```bash
printf '\x90' | sudo dd of=/sys/kernel/debug/ec/ec0/io bs=1 seek=<OFFSET> count=1 conv=notrunc
```

If the fans get louder and the value holds, it's a writable fan register. A reboot reverts everything.

---

## Why not just...

- **`hp-wmi` / `pwm1_enable`** — firmware WMI methods are broken on 8BCA (`pwm1` never appears; boost flips back instantly).
- **Linux 6.20+ upstream fan patch / `arfelious/omen-fan-control`** — backports the WMI-based driver; same broken firmware methods → no `pwm1`.
- **Newer kernel for `platform_profile`** — mainline 7.0 needs glibc ≥ 2.38 (Ubuntu 22.04 ships 2.35); 22.04 OEM kernels stop at 6.5. Upgrading the distro breaks Isaac Sim / ROS toolchains.
- **`ryzenadj` TDP cap** — works, but caps performance. This keeps full performance and cools with the fans instead. (You *can* still add `ryzenadj --tctl-temp=95` as a last-resort safety net alongside this.)

---

## License

MIT. Provided as-is, no warranty.
