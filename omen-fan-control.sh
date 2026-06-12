#!/bin/bash
#
# OMEN 16-xf0052AX (board 8BCA) EC fan control daemon
# Linear-interpolated temperature curve + keep-alive + 90C emergency override.
#
# EC registers (found by observation on board 8BCA):
#   0xB0 (skip 176) = CPU temperature (C)
#   0xB2 (seek 178) = fan1 speed (write, 0..0x90 saturates)
#   0xB4 (seek 180) = fan2 speed (write, 0..0x90 saturates)
#
# The firmware periodically overwrites the fan registers, so every loop
# rewrites them (keep-alive). On exit, control reverts to the firmware.
#
# USE AT YOUR OWN RISK. Offsets are model-specific (8BCA). See README.

EC=/sys/kernel/debug/ec/ec0/io
INTERVAL=1
TEMP_OFF=176        # 0xB0
FAN1_OFF=178        # 0xB2
FAN2_OFF=180        # 0xB4

FAN_MIN=24          # 0x18 quiet minimum (fans never fully stop)
FAN_MAX=144         # 0x90 saturation (curve ceiling)
FAN_EMERGENCY=255   # 0xFF emergency
EMERGENCY=90        # >= this temp -> 0xFF

# Curve vertices (temp C : fan value 0-144), ascending; linear between points.
CURVE_TEMPS=(40 55 70 85)
CURVE_FANS=( 24 60 100 144)

ensure_ec(){ [ -e "$EC" ] || { modprobe -r ec_sys 2>/dev/null; modprobe ec_sys write_support=1; }; }

read_temp(){ printf '%d' "0x$(dd if=$EC bs=1 skip=$TEMP_OFF count=1 2>/dev/null | xxd -p)"; }

write_fan(){
  local h; printf -v h '\\x%02x' "$1"
  printf "$h" | dd of=$EC bs=1 seek=$FAN1_OFF count=1 conv=notrunc 2>/dev/null
  printf "$h" | dd of=$EC bs=1 seek=$FAN2_OFF count=1 conv=notrunc 2>/dev/null
}

interp(){
  local t=$1 n=${#CURVE_TEMPS[@]} i lo_t hi_t lo_f hi_f
  if [ "$t" -le "${CURVE_TEMPS[0]}" ]; then echo "${CURVE_FANS[0]}"; return; fi
  if [ "$t" -ge "${CURVE_TEMPS[$((n-1))]}" ]; then echo "${CURVE_FANS[$((n-1))]}"; return; fi
  for ((i=0;i<n-1;i++)); do
    lo_t=${CURVE_TEMPS[i]}; hi_t=${CURVE_TEMPS[i+1]}
    if [ "$t" -ge "$lo_t" ] && [ "$t" -lt "$hi_t" ]; then
      lo_f=${CURVE_FANS[i]}; hi_f=${CURVE_FANS[i+1]}
      echo $(( lo_f + (t-lo_t)*(hi_f-lo_f)/(hi_t-lo_t) )); return
    fi
  done
  echo "$FAN_MAX"
}

cleanup(){ echo; echo "[omen-fan] stop -> firmware control"; exit 0; }
trap cleanup SIGINT SIGTERM

echo "[omen-fan] started (8BCA, curve + 90C emergency 0xFF)"
ensure_ec

while true; do
  ensure_ec
  temp=$(read_temp 2>/dev/null)
  if ! [[ "$temp" =~ ^[0-9]+$ ]]; then
    write_fan "$FAN_EMERGENCY"; sleep "$INTERVAL"; continue
  fi
  if [ "$temp" -ge "$EMERGENCY" ]; then
    fan=$FAN_EMERGENCY
  else
    fan=$(interp "$temp")
    [ "$fan" -lt "$FAN_MIN" ] && fan=$FAN_MIN
    [ "$fan" -gt "$FAN_MAX" ] && fan=$FAN_MAX
  fi
  write_fan "$fan"
  printf '\r[omen-fan] %d C -> fan %d   ' "$temp" "$fan"
  sleep "$INTERVAL"
done
