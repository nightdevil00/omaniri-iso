#!/bin/bash

set -e

read_package_file() {
  local file="$1"
  [[ -f $file ]] || return 0
  sed 's/#.*//' "$file" | awk 'NF {print $1}'
}

join_packages() {
  local file="$1"
  [[ -s $file ]] || return 0
  tr '\n' ' ' <"$file"
}

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub pacman-contrib curl

# Verify Arch Linux keyring is available
pacman --noconfirm -Sy archlinux-keyring

# makepkg and yay use /etc/pacman.conf for dependency resolution.
# Use the same repo config as the offline downloader so multilib dependencies are available.
cp /configs/pacman-online.conf /etc/pacman.conf
pacman --noconfirm -Sy

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omaniri/mirror/offline"
package_work_dir="/tmp/omaniri-package-lists"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/
mkdir -p "$package_work_dir"

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/

# Remove Arch releng boot entries that should not appear on the Omaniri ISO.
rm -f "$build_cache_dir/efiboot/loader/entries/"*.conf
cp -r /configs/efiboot/loader/entries/* "$build_cache_dir/efiboot/loader/entries/"



# Setup Omaniri itself
if [[ -d /omaniri ]]; then
  cp -rp /omaniri "$build_cache_dir/airootfs/root/omaniri"
else
  git clone -b $OMANIRI_INSTALLER_REF https://github.com/$OMANIRI_INSTALLER_REPO.git "$build_cache_dir/airootfs/root/omaniri"
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omaniri/bin/omaniri-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omaniri-upload-log"

# Copy the Omaniri Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omaniri"
cp -r "$build_cache_dir/airootfs/root/omaniri/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omaniri/"

# Download and verify Node.js binary for offline installation
# Pin to specific LTS version for reproducibility
NODE_VERSION="v22.17.1"
NODE_DIST_URL="https://nodejs.org/dist/$NODE_VERSION"

# Get checksums and parse filename and SHA
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "linux-x64.tar.gz" | awk '{print $1}')

# Download the tarball
curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "/tmp/$NODE_FILENAME"

# Verify SHA256 checksum
echo "$NODE_SHA /tmp/$NODE_FILENAME" | sha256sum -c - || {
    echo "ERROR: Node.js checksum verification failed!"
    exit 1
}

# Copy to ISO
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "/tmp/$NODE_FILENAME" "$build_cache_dir/airootfs/opt/packages/"

# Add our additional packages to packages.x86_64
arch_packages=(linux git gum jq openssl plymouth tzupdate lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build package source lists for the offline mirror
{
  read_package_file "$build_cache_dir/packages.x86_64"
  read_package_file "$build_cache_dir/airootfs/root/omaniri/install/omaniri-base.packages"
  read_package_file "$build_cache_dir/airootfs/root/omaniri/install/omaniri-other.packages"
  read_package_file /builder/archinstall.packages
} | sort -u >"$package_work_dir/all.packages"

read_package_file /builder/aur.packages | sort -u >"$package_work_dir/aur.packages"
read_package_file /builder/aur-skipchecksums.packages | sort -u >"$package_work_dir/aur-skipchecksums.packages"
read_package_file /builder/chaotic.packages | sort -u >"$package_work_dir/chaotic.packages"
cat "$package_work_dir/aur.packages" "$package_work_dir/chaotic.packages" | sort -u >"$package_work_dir/non-pacman.packages"
comm -23 "$package_work_dir/all.packages" "$package_work_dir/non-pacman.packages" >"$package_work_dir/pacman.packages"

# Download official Arch packages to the offline mirror inside the ISO
# Use a shared offlinedb so version resolution is consistent across all download steps.
# Previous approach used per-step databases which allowed version skew (e.g., ffmpeg
# needing libjxl.so=0.11 but mirror having libjxl-0.12 from a different download step).
mkdir -p /tmp/offlinedb
if [[ -s "$package_work_dir/pacman.packages" ]]; then
  pacman --config /configs/pacman-online.conf --noconfirm -Syw $(join_packages "$package_work_dir/pacman.packages") --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb
fi

# Download selected Chaotic-AUR binary packages.
# Use the shared offlinedb for consistent version resolution.
if [[ -s "$package_work_dir/chaotic.packages" ]]; then
  chaotic_conf=/tmp/pacman-chaotic.conf
  cp /configs/pacman-online.conf "$chaotic_conf"
  cat <<'EOF' >>"$chaotic_conf"

[chaotic-aur]
SigLevel = Never
Server = https://geo-mirror.chaotic.cx/$repo/$arch
EOF
  pacman --config "$chaotic_conf" --noconfirm -Syw $(join_packages "$package_work_dir/chaotic.packages") --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb
fi

# Ensure /usr/lib/modules exists so DKMS post-transaction hooks
# (e.g. nvidia-580xx-dkms) don't abort the build in containers
# that lack kernel modules.
mkdir -p /usr/lib/modules

# Build AUR packages and copy the resulting package files into the offline mirror.
if [[ -s "$package_work_dir/aur.packages" ]]; then
  useradd -m -G wheel aurbuilder
  printf 'aurbuilder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/aurbuilder
  chmod 440 /etc/sudoers.d/aurbuilder

  install -d -o aurbuilder -g aurbuilder /tmp/aur-build
  install -d -m 0755 -o aurbuilder -g aurbuilder /tmp/aur-build/cache
  install -d -m 0755 -o aurbuilder -g aurbuilder /tmp/aur-build/cache/yay
  install -d -m 0755 -o aurbuilder -g aurbuilder /tmp/aur-build/cache/go-build
  install -d -m 0755 -o aurbuilder -g aurbuilder /tmp/aur-build/cache/xdg-terminal-exec
  install -d -m 0755 -o aurbuilder -g aurbuilder /tmp/aur-build/config/yay
  chown -R aurbuilder:aurbuilder /tmp/aur-build /home/aurbuilder

  aur_env=(
    HOME=/home/aurbuilder
    XDG_CONFIG_HOME=/tmp/aur-build/config
    XDG_CACHE_HOME=/tmp/aur-build/cache
    GOCACHE=/tmp/aur-build/cache/go-build
    MAKEFLAGS=-j$(nproc)
    PKGEXT=.pkg.tar
  )
  sudo -u aurbuilder env "${aur_env[@]}" bash -lc '
    set -e
    test "$HOME" = /home/aurbuilder
    mkdir -p "$XDG_CONFIG_HOME/yay"
    mkdir -p "$GOCACHE" "$XDG_CACHE_HOME/yay" "$XDG_CACHE_HOME/xdg-terminal-exec"
    test -w "$HOME"
    test -w "$XDG_CONFIG_HOME"
    test -w "$XDG_CACHE_HOME"
    test -w "$GOCACHE"
    cat >"$XDG_CONFIG_HOME/yay/config.json" <<'"'"'EOF'"'"'
{
  "provides": false
}
EOF
    touch "$GOCACHE/.write-test" "$XDG_CACHE_HOME/xdg-terminal-exec/.write-test"
    rm -f "$GOCACHE/.write-test" "$XDG_CACHE_HOME/xdg-terminal-exec/.write-test"
  '

  yay_flags=(
    --noconfirm
    --needed
    --cleanmenu=false
    --diffmenu=false
    --editmenu=false
    --removemake
  )
  install_aur_packages() {
    local file="$1"
    local mflags="$2"
    [[ -s $file ]] || return 0
    sudo -u aurbuilder env "${aur_env[@]}" yay -S "${yay_flags[@]}" --mflags "$mflags" $(join_packages "$file")
  }

  if grep -Fxq yay-bin "$package_work_dir/aur.packages"; then
    sudo -u aurbuilder env "${aur_env[@]}" git clone https://aur.archlinux.org/yay-bin.git /tmp/aur-build/yay-bin
    sudo -u aurbuilder env "${aur_env[@]}" bash -lc 'cd /tmp/aur-build/yay-bin && makepkg -si --noconfirm --nocheck'
  fi

  grep -Fvx yay-bin "$package_work_dir/aur.packages" >"$package_work_dir/aur-without-yay.packages" || true
  comm -12 "$package_work_dir/aur-without-yay.packages" "$package_work_dir/aur-skipchecksums.packages" >"$package_work_dir/aur-without-yay-skipchecksums.packages"
  comm -23 "$package_work_dir/aur-without-yay.packages" "$package_work_dir/aur-without-yay-skipchecksums.packages" >"$package_work_dir/aur-without-yay-strict.packages"

  install_aur_packages "$package_work_dir/aur-without-yay-strict.packages" "--skippgpcheck --nocheck"
  install_aur_packages "$package_work_dir/aur-without-yay-skipchecksums.packages" "--skippgpcheck --skipchecksums --nocheck"

  find /tmp/aur-build /var/cache/pacman/pkg -type f \( -name '*.pkg.tar' -o -name '*.pkg.tar.zst' -o -name '*.pkg.tar.xz' -o -name '*.pkg.tar.gz' \) -exec cp -n {} "$offline_mirror_dir/" \;
fi

shopt -s nullglob

# Cleanup: remove AUR build dependencies that leaked into the offline mirror
for pkg in clang rust go deno; do
  rm -f "$offline_mirror_dir/$pkg-"*.pkg.tar*
done

# Cleanup: deduplicate packages keeping only the latest version
for pkg in zed; do
  pkgs=("$offline_mirror_dir/$pkg-"*.pkg.tar*)
  if ((${#pkgs[@]} > 1)); then
    latest=$(printf '%s\n' "${pkgs[@]}" | sort -V | tail -1)
    for f in "${pkgs[@]}"; do
      [ "$f" != "$latest" ] && rm -f "$f"
    done
  fi
done

repo_packages=("$offline_mirror_dir/"*.pkg.tar "$offline_mirror_dir/"*.pkg.tar.zst "$offline_mirror_dir/"*.pkg.tar.xz "$offline_mirror_dir/"*.pkg.tar.gz)
if ((${#repo_packages[@]} > 0)); then
  repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "${repo_packages[@]}"
else
  echo "ERROR: No packages found in offline mirror directory" >&2
  exit 1
fi

# Create a symlink to the offline mirror instead of duplicating it.
# mkarchiso needs packages at /var/cache/omaniri/mirror/offline in the container,
# but they're actually in $build_cache_dir/airootfs/var/cache/omaniri/mirror/offline
mkdir -p /var/cache/omaniri/mirror
ln -s "$offline_mirror_dir" "/var/cache/omaniri/mirror/offline"

# Copy the offline pacman.conf to the ISO's /etc directory so the live environment uses our
# same config when booted. 
cp $build_cache_dir/pacman-offline.conf "$build_cache_dir/airootfs/etc/pacman.conf"

# Finally, we assemble the entire ISO
mkarchiso -v -w "$build_cache_dir/work/" -o "/out/" "$build_cache_dir/"

# Fix ownership of output files to match host user
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
    chown -R "$HOST_UID:$HOST_GID" /out/
fi
