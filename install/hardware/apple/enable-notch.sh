# Use the full Apple Silicon (Asahi) display height, including the strip beside
# the notch, so the top of the screen is usable for the Omarchy bar. Without
# this, Asahi crops the display below the notch. Only applies where the appledrm
# display driver exists (Apple Silicon); a no-op on T2 Intel Macs and non-Macs.
conf="${OMARCHY_ASAHI_NOTCH_CONF:-/etc/modprobe.d/asahi-notch.conf}"
if modinfo appledrm &>/dev/null && [[ ! -f $conf ]]; then
  echo "Enabling Asahi notch area (full display height) for the Omarchy bar"
  sudo mkdir -p "$(dirname "$conf")"
  echo "options appledrm show_notch=1" | sudo tee "$conf" >/dev/null
fi
