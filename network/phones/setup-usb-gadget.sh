#!/bin/sh
# /usr/local/bin/setup-usb-gadget.sh on each phone (postmarketOS)
# USB Gadget configuration: NCM (networking) + ACM (serial console).
#
# The block setting host_addr / dev_addr pins the gadget MAC across reboots so
# the laptop-side udev rule can match a stable identifier instead of a name
# that rotates with each boot.
#
# Replace the MAC pair with the phone-specific values from phones/macs.env.

GADGET_DIR="/sys/kernel/config/usb_gadget/g1"
CONFIG_DIR="${GADGET_DIR}/configs/c.1"
FUNCTIONS_DIR="${GADGET_DIR}/functions"

sleep 1

if [ -f "${GADGET_DIR}/UDC" ] && [ -n "$(cat ${GADGET_DIR}/UDC)" ]; then
    UDC_NAME=$(cat ${GADGET_DIR}/UDC)
    echo "" > ${GADGET_DIR}/UDC
else
    UDC_NAME=$(ls /sys/class/udc/ | head -n1)
fi

# --- Per-phone MAC pinning (replace with values from macs.env) ---
if [ -d "${FUNCTIONS_DIR}/ncm.usb0" ]; then
    echo "00:00:00:00:00:01" > ${FUNCTIONS_DIR}/ncm.usb0/host_addr
    echo "00:00:00:00:00:02" > ${FUNCTIONS_DIR}/ncm.usb0/dev_addr
fi
# -----------------------------------------------------------------

[ -d "${FUNCTIONS_DIR}/ncm.usb0" ] || mkdir -p ${FUNCTIONS_DIR}/ncm.usb0
[ -d "${FUNCTIONS_DIR}/acm.usb1" ] || mkdir -p ${FUNCTIONS_DIR}/acm.usb1
[ -d "${CONFIG_DIR}" ]            || mkdir -p ${CONFIG_DIR}
[ -L "${CONFIG_DIR}/ncm.usb0" ]   || ln -s ${FUNCTIONS_DIR}/ncm.usb0 ${CONFIG_DIR}/
[ -L "${CONFIG_DIR}/acm.usb1" ]   || ln -s ${FUNCTIONS_DIR}/acm.usb1 ${CONFIG_DIR}/

if [ -n "$UDC_NAME" ]; then
    echo "$UDC_NAME" > ${GADGET_DIR}/UDC
fi

exit 0
