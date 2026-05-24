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

get_codename() {
  local codename=""
  if [ -r /etc/os-release ]; then
    codename="$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)"
  fi
  if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -sc 2>/dev/null || true)"
  fi
  if [ -z "$codename" ]; then
    echo "Could not determine release codename" >&2
    exit 1
  fi
  printf '%s\n' "$codename"
}

backports_repo_present() {
  local codename="$1"
  grep -RhsE "^[[:space:]]*deb[[:space:]].*[[:space:]]${codename}-backports[[:space:]]" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null \
    | grep -q .
}

add_backports_repo() {
  local codename="$1"
  cat > /etc/apt/sources.list.d/devuan-backports.list <<EOF
deb http://deb.devuan.org/merged ${codename}-backports main
EOF
}

mesa_backports_check() {
  local codename="$1"
  local mesa_pkgs=(
    libgl1-mesa-dri
    libglx-mesa0
    mesa-vulkan-drivers
    mesa-va-drivers
    mesa-vdpau-drivers
  )
  local need_backports=0
  local pkg ver reply

  for pkg in "${mesa_pkgs[@]}"; do
    ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    if [ -z "$ver" ] || [[ "$ver" != *~bpo* ]]; then
      need_backports=1
      break
    fi
  done

  if [ "$need_backports" -eq 0 ]; then
    log "Mesa backports already installed"
    return 0
  fi

  log "Mesa backports not detected"

  if ! backports_repo_present "$codename"; then
    read -r -p "Devuan backports repo is not configured. Add it? [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS])
        log "Adding Devuan backports repository"
        add_backports_repo "$codename"
        apt update
        ;;
      *)
        echo "Skipping Mesa backports setup."
        return 0
        ;;
    esac
  fi

  read -r -p "Install Mesa drivers from ${codename}-backports? (includes multiarch setup for Steam) [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS])
      log "Installing Mesa backports packages (amd64)..."
      apt install -y -t "${codename}-backports" "${mesa_pkgs[@]}"

      log "Configuring Mesa multiarch pinning for ${codename}-backports..."
      cat > /etc/apt/preferences.d/mesa-multiarch <<EOF
Package: libgbm1 libgbm1:i386 \\
         libgl1-mesa-dri libgl1-mesa-dri:i386 \\
         libegl-mesa0 libegl-mesa0:i386 \\
         libglx-mesa0 libglx-mesa0:i386
Pin: release n=${codename}-backports
Pin-Priority: 501
EOF

      apt update

      log "Installing Mesa multiarch stack from ${codename}-backports..."
      apt install -y \
        libgbm1 libgbm1:i386 \
        libgl1-mesa-dri libgl1-mesa-dri:i386 \
        libegl-mesa0 libegl-mesa0:i386 \
        libglx-mesa0 libglx-mesa0:i386

      log "Installing GL/EGL interface libs (for native Steam)..."
      apt install -y \
        libegl1 libegl1:i386 \
        libgl1 libgl1:i386
      ;;
    *)
      echo "Skipping Mesa backports installation."
      ;;
  esac
}

CODENAME="$(get_codename)"

log "Enabling i386 multiarch (needed for native Steam & 32-bit games)..."
dpkg --add-architecture i386 || true
apt update

log "Installing packages"
apt install -y \
  flatpak pipewire wireplumber pipewire-pulse pipewire-audio \
  pulseaudio-utils alsa-utils plasma-pa dbus elogind

mesa_backports_check "$CODENAME"

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

# Esync settings for non-systemd distros
grep -q "^${TARGET_USER} hard nofile 524288$" /etc/security/limits.conf 2>/dev/null || \
  echo "$TARGET_USER hard nofile 524288" >> /etc/security/limits.conf

echo "fs.inotify.max_user_instances=1024" | sudo tee /etc/sysctl.d/99-inotify.conf
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.d/99-inotify.conf

log "Done"
echo "Now log out and back in, then test with:"
echo "  flatpak remotes --user"
echo "  flatpak install --user flathub com.valvesoftware.Steam"
echo "  flatpak run com.valvesoftware.Steam"
echo "  speaker-test -c 2"
