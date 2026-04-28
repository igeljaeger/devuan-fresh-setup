#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root with sudo: sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "Run this with sudo from your normal desktop user, not as a direct root login." >&2
  exit 1
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "Could not determine home directory for $TARGET_USER" >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
run_user() { sudo -u "$TARGET_USER" env HOME="$USER_HOME" "$@"; }

log "Installing packages"
apt update
apt install -y \
  flatpak pipewire wireplumber pipewire-pulse pipewire-audio \
  pulseaudio-utils alsa-utils plasma-pa dbus elogind

log "Adding Flathub for user install scope"
run_user flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

log "Enabling unprivileged user namespaces for Flatpak and Steam"
cat > /etc/sysctl.d/40-flatpak-userns.conf <<'EOS'
kernel.unprivileged_userns_clone=1
EOS
sysctl --system >/dev/null || true

log "Creating KDE autostart script for PipeWire audio"
install -d -o "$TARGET_USER" -g "$TARGET_USER" \
  "$USER_HOME/.config/autostart" \
  "$USER_HOME/.config/autostart-scripts"

cat > "$USER_HOME/.config/autostart-scripts/pipewire-start.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
pkill -u "$USER" -fx /usr/bin/pipewire-pulse >/dev/null 2>&1 || true
pkill -u "$USER" -fx /usr/bin/wireplumber >/dev/null 2>&1 || true
pkill -u "$USER" -fx /usr/bin/pipewire >/dev/null 2>&1 || true
/usr/bin/pipewire &
while ! pgrep -u "$USER" -fx /usr/bin/pipewire >/dev/null 2>&1; do sleep 1; done
/usr/bin/wireplumber &
while ! pgrep -u "$USER" -fx /usr/bin/wireplumber >/dev/null 2>&1; do sleep 1; done
/usr/bin/pipewire-pulse &
EOS
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/autostart-scripts/pipewire-start.sh"
chmod 755 "$USER_HOME/.config/autostart-scripts/pipewire-start.sh"

cat > "$USER_HOME/.config/autostart/pipewire-start.desktop" <<EOF2
[Desktop Entry]
Type=Application
Version=1.0
Name=PipeWire Session
Comment=Start PipeWire, WirePlumber and pipewire-pulse for Plasma on Devuan
Exec=$USER_HOME/.config/autostart-scripts/pipewire-start.sh
X-GNOME-Autostart-enabled=true
NoDisplay=false
Terminal=false
EOF2
chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/autostart/pipewire-start.desktop"
chmod 644 "$USER_HOME/.config/autostart/pipewire-start.desktop"

#Esync settings for non-systemd distros (source: https://github.com/lutris/docs/blob/master/HowToEsync.md)
echo "$TARGET_USER hard nofile 524288" >> /etc/security/limits.conf

log "Done"
echo "Now log out and back in, then test with:"
echo "  flatpak remotes --user"
echo "  flatpak install --user flathub com.valvesoftware.Steam"
echo "  flatpak run com.valvesoftware.Steam"
echo "  speaker-test -c 2"
