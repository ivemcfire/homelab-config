#!/bin/sh
# Patch the device tree on a OnePlus 6/6T running postmarketOS to cap charge
# voltage at ~3.8 V (~70% SoC), so the cell does not swell while the phone is
# always on AC.
#
# Voltage values:
#   stock:   0x432380 = 4,399,936 microvolt = 4.4 V
#   capped:  0x39f740 = 3,800,000 microvolt = 3.8 V
#
# Run as root on the phone. After reboot, verify with:
#   xxd /sys/firmware/devicetree/base/battery/voltage-max-design-microvolt
#
# Note: if the cell is currently above 3.8 V at boot, the charger simply stops
# until natural discharge brings it under the new ceiling. That is correct.

set -eu

DTB=""
case "$(uname -n)" in
  one6t|*fajita*)          DTB=/boot/sdm845-oneplus-fajita.dtb ;;
  one61|one62|*enchilada*) DTB=/boot/sdm845-oneplus-enchilada.dtb ;;
  *)                       DTB="${1:-}" ;;
esac
[ -n "$DTB" ] || { echo "usage: $0 <path-to-dtb>"; exit 1; }
[ -f "$DTB" ] || { echo "DTB not found: $DTB"; exit 1; }

apk add dtc 2>/dev/null || true

cp "$DTB" "$DTB.bak"
TMP="$(mktemp /tmp/dtb-XXXX.dts)"
dtc -I dtb -O dts -o "$TMP" "$DTB" 2>/dev/null
sed -i 's/voltage-max-design-microvolt = <0x432380>/voltage-max-design-microvolt = <0x39f740>/' "$TMP"
dtc -I dts -O dtb -o "$DTB" "$TMP" 2>/dev/null
rm -f "$TMP"

echo "patched $DTB; backup at $DTB.bak; reboot to apply."
