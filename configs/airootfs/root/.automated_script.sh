#!/usr/bin/env bash
set -euo pipefail

use_omaniri_helpers() {
  export OMANIRI_PATH="/root/omaniri"
  export OMANIRI_INSTALL="/root/omaniri/install"
  export OMANIRI_INSTALL_LOG_FILE="/var/log/omaniri-install.log"
  source /root/omaniri/install/helpers/all.sh
}

run_configurator() {
  set_tokyo_night_colors
  ./configurator
  export OMANIRI_USER="$(jq -r '.users[0].username' user_credentials.json)"
}

install_arch() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Installing..."
  echo

  touch /var/log/omaniri-install.log

  start_log_output

  # Set CURRENT_SCRIPT for the trap to display better when nothing is returned for some reason
  CURRENT_SCRIPT="install_base_system"
  install_base_system > >(sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g' >>/var/log/omaniri-install.log) 2>&1
  unset CURRENT_SCRIPT
  stop_log_output
}

install_omaniri() {
  clear_logo
  gum style --foreground 3 --padding "1 0 0 $PADDING_LEFT" "Configuring Omaniri desktop environment..."
  echo

  # gum is already installed by archinstall via archinstall.packages, no need to reinstall
  chroot_bash -lc "source /home/$OMANIRI_USER/.local/share/omaniri/install.sh || bash"

  # Reboot if requested by installer
  if [[ -f /mnt/var/tmp/omaniri-install-completed ]]; then
    reboot
  fi
}

# Set Tokyo Night color scheme for the terminal
set_tokyo_night_colors() {
  if [[ $(tty) == "/dev/tty"* ]]; then
    # Tokyo Night color palette
    echo -en "\e]P01a1b26" # black (background)
    echo -en "\e]P1f7768e" # red
    echo -en "\e]P29ece6a" # green
    echo -en "\e]P3e0af68" # yellow
    echo -en "\e]P47aa2f7" # blue
    echo -en "\e]P5bb9af7" # magenta
    echo -en "\e]P67dcfff" # cyan
    echo -en "\e]P7a9b1d6" # white
    echo -en "\e]P8414868" # bright black
    echo -en "\e]P9f7768e" # bright red
    echo -en "\e]PA9ece6a" # bright green
    echo -en "\e]PBe0af68" # bright yellow
    echo -en "\e]PC7aa2f7" # bright blue
    echo -en "\e]PDbb9af7" # bright magenta
    echo -en "\e]PE7dcfff" # bright cyan
    echo -en "\e]PFc0caf5" # bright white (foreground)

    # Set default foreground and background
    echo -en "\033[0m"
    clear
  fi
}

install_disk() {
  jq -er 'first(.disk_config.device_modifications[]? | select(.wipe == true) | .device)' user_configuration.json
}

cleanup_install_disk() {
  local disk="$1"

  if [[ -z "$disk" || ! -b "$disk" ]]; then
    echo "Could not determine install disk for cleanup" >&2
    return 1
  fi

  echo "Cleaning up existing holders on install disk: $disk"

  # Ensure that no mounts exist from past install attempts.
  findmnt -R /mnt >/dev/null && umount -R /mnt || true

  # Turn off swap and unmount anything backed by the selected disk, including
  # device-mapper children from a previous install. Active LVM/swap holders can
  # prevent the kernel from re-reading the partition table after archinstall
  # wipes and recreates it.
  while read -r dev; do
    [[ -b "$dev" ]] || continue

    swapoff "$dev" 2>/dev/null || true

    while read -r target; do
      [[ -n "$target" ]] || continue
      umount "$target" 2>/dev/null || true
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
  done < <(lsblk -rnpo PATH "$disk")

  # Deactivate any LVM volume groups whose physical volumes live on the selected
  # disk. This is the common case when replacing Fedora/Alma/RHEL installs.
  while read -r dev type; do
    [[ "$type" == "disk" || "$type" == "part" || "$type" == "crypt" ]] || continue

    while read -r vg; do
      [[ -n "$vg" ]] || continue
      vgchange -an "$vg" 2>/dev/null || true
    done < <(pvs --noheadings -o vg_name "$dev" 2>/dev/null | awk '{$1=$1; print}' | sort -u)
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  # Close any LUKS mappings stacked on the selected disk after filesystems and
  # swap have been released.
  while read -r dev type; do
    [[ "$type" == "crypt" ]] || continue
    cryptsetup close "$dev" 2>/dev/null || true
  done < <(lsblk -rnpo PATH,TYPE "$disk")

  blockdev --flushbufs "$disk" 2>/dev/null || true
  partprobe "$disk" 2>/dev/null || true
  udevadm settle || true
}

install_base_system() {
  # Initialize and populate the keyring
  pacman-key --init
  pacman-key --populate archlinux
  # Keyring already populated by archlinux-keyring

  # Sync the offline database so pacman can find packages
  pacman -Sy --noconfirm

  cleanup_install_disk "$(install_disk)"

  # Workarounds for archinstall regressions under Python 3.14:
  # 1. sync_log_to_install_medium: `self.target / absolute_logfile` drops
  #    self.target because the RHS is absolute, so Path.copy() raises EINVAL
  #    (source == target).
  # 2. _add_limine_bootloader: `Path.copy(efi_dir_path)` raises IsADirectoryError
  #    because 3.14's Path.copy treats target as a literal path, not a directory
  #    (shutil.copy used to auto-append the source filename).
  if [[ -f /usr/lib/python3*/site-packages/archinstall/lib/installer.py ]]; then
    sed -i \
      -e 's|logfile_target = self\.target / absolute_logfile$|logfile_target = self.target / absolute_logfile.relative_to("/")|' \
      -e 's|(limine_path / file)\.copy(efi_dir_path)|(limine_path / file).copy(efi_dir_path / file)|' \
      -e "s|(limine_path / 'limine-bios.sys')\.copy(boot_limine_path)|(limine_path / 'limine-bios.sys').copy(boot_limine_path / 'limine-bios.sys')|" \
      /usr/lib/python3*/site-packages/archinstall/lib/installer.py
  fi

  # Install using files generated by the ./configurator
  # Skip NTP and WKD sync since we're offline (keyring is pre-populated in ISO)
  archinstall \
    --config user_configuration.json \
    --creds user_credentials.json \
    --silent \
    --skip-ntp \
    --skip-wkd \
    --skip-wifi-check

  # After archinstall sets up the base system but before our installer runs,
  # we need to ensure the offline pacman.conf is in place
  cp /etc/pacman.conf /mnt/etc/pacman.conf

  # Mount the offline mirror so it's accessible in the chroot
  mkdir -p /mnt/var/cache/omaniri/mirror/offline
  mount --bind /var/cache/omaniri/mirror/offline /mnt/var/cache/omaniri/mirror/offline

  # Mount the packages dir so it's accessible in the chroot
  mkdir -p /mnt/opt/packages
  mount --bind /opt/packages /mnt/opt/packages

  # No need to ask for sudo during the installation (omaniri itself responsible for removing after install)
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-omaniri-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$OMANIRI_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-omaniri-installer

  # Copy the local omaniri repo to the user's home directory
  mkdir -p /mnt/home/$OMANIRI_USER/.local/share/
  cp -r /root/omaniri /mnt/home/$OMANIRI_USER/.local/share/

  # Get the user's UID from the system (defaults to 1000 if lookup fails)
  local user_uid
  user_uid=$(id -u "$OMANIRI_USER" 2>/dev/null || echo 1000)
  chown -R "$user_uid:$user_uid" /mnt/home/$OMANIRI_USER/.local/

  # NOPASSWD sudo already configured — no-op the keepalive to avoid password prompt
  > /mnt/home/$OMANIRI_USER/.local/share/omaniri/bin/omaniri-sudo-keepalive

  # Ensure all necessary scripts are executable
  find /mnt/home/$OMANIRI_USER/.local/share/omaniri -type f -path "*/bin/*" -exec chmod +x {} \;
  chmod +x /mnt/home/$OMANIRI_USER/.local/share/omaniri/boot.sh 2>/dev/null || true
  find /mnt/home/$OMANIRI_USER/.local/share/omaniri/default/waybar -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
}

chroot_bash() {
  HOME=/home/$OMANIRI_USER \
    arch-chroot -u $OMANIRI_USER /mnt/ \
    env OMANIRI_CHROOT_INSTALL=1 \
    OMANIRI_USER_NAME="$(<user_full_name.txt)" \
    OMANIRI_USER_EMAIL="$(<user_email_address.txt)" \
    USER="$OMANIRI_USER" \
    HOME="/home/$OMANIRI_USER" \
    /bin/bash "$@"
}

if [[ $(tty) == "/dev/tty1" ]]; then
  use_omaniri_helpers
  run_configurator
  install_arch
  install_omaniri
fi
