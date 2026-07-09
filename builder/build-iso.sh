#!/bin/bash

set -e

# Note that these are packages installed to the Arch container used to build the ISO.
pacman-key --init
pacman --noconfirm -Sy archlinux-keyring
pacman --noconfirm -Sy archiso git sudo base-devel jq grub

# Verify Arch Linux keyring is available
pacman --noconfirm -Sy archlinux-keyring

# Setup build locations
build_cache_dir="/var/cache"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omaniri/mirror/offline"
mkdir -p $build_cache_dir/
mkdir -p $offline_mirror_dir/

# We base our ISO on the official arch ISO (releng) config
cp -r /archiso/configs/releng/* $build_cache_dir/
rm "$build_cache_dir/airootfs/etc/motd"

# Avoid using reflector for mirror identification as we are relying on the global CDN
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our configs
cp -r /configs/* $build_cache_dir/



# Setup Omaniri itself
if [[ -d /omaniri ]]; then
  cp -rp /omaniri "$build_cache_dir/airootfs/root/omaniri"
else
  git clone -b $OMANIRI_INSTALLER_REF https://github.com/niraletter/omaniri.git "$build_cache_dir/airootfs/root/omaniri"
fi

# Make log uploader available in the ISO too
mkdir -p "$build_cache_dir/airootfs/usr/local/bin/"
cp "$build_cache_dir/airootfs/root/omaniri/bin/omaniri-upload-log" "$build_cache_dir/airootfs/usr/local/bin/omaniri-upload-log"

# Copy the Omaniri Plymouth theme to the ISO
mkdir -p "$build_cache_dir/airootfs/usr/share/plymouth/themes/omaniri"
cp -r "$build_cache_dir/airootfs/root/omaniri/default/plymouth/"* "$build_cache_dir/airootfs/usr/share/plymouth/themes/omaniri/"

# Download and verify Node.js binary for offline installation
NODE_DIST_URL="https://nodejs.org/dist/latest"

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
arch_packages=(linux git gum jq openssl plymouth lvm2 cryptsetup parted)
printf '%s\n' "${arch_packages[@]}" >>"$build_cache_dir/packages.x86_64"

# Build list of all the packages needed for the offline mirror
all_packages=($(cat "$build_cache_dir/packages.x86_64"))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omaniri/install/omaniri-base.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' "$build_cache_dir/airootfs/root/omaniri/install/omaniri-other.packages" | grep -v '^$'))
all_packages+=($(grep -v '^#' /builder/archinstall.packages | grep -v '^$'))

# Add Chaotic-AUR repo for pre-built AUR package binaries (avoids source compilation)
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
pacman-key --lsign-key 3056513887B78AEB
pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
pacman --noconfirm -U 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
cat >> /etc/pacman.conf << 'EOF'

[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
EOF

# Sync Chaotic-AUR database (pacman -Sy only, not -Syu, to avoid kernel upgrades inside builder)
pacman -Sy

# Re-install base-devel after Chaotic-AUR sync so all group members are resolvable
pacman --noconfirm -S base-devel

all_packages+=(yay-bin)

useradd -m builder
echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
mkdir -p /tmp/aur-build /tmp/offlinedb
chown builder:builder /tmp/aur-build

# Install common build dependencies for AUR packages (Rust, Go) in the builder container
# so makepkg -s does not prompt for provider selection during dependency resolution
pacman --noconfirm -S rust go

# Exclude AUR-only packages from pacman -Syw (they cannot be in any repo).
# The AUR build loop below handles them from source.
# yaru-icon-theme is from Chaotic-AUR; asusctl is not in the ISO, installed later.
aur_only=($(grep -v '^#' "$build_cache_dir/airootfs/root/omaniri/install/aur-only.packages" | grep -v '^$'))
aur_only+=(yay-bin)
filtered_packages=($(comm -23 \
  <(printf '%s\n' "${all_packages[@]}" | sort -u) \
  <(printf '%s\n' "${aur_only[@]}" | sort -u) ))

# Download all resolvable packages from official repos + Chaotic-AUR into the offline mirror
# Pipe yes "1" to auto-select first provider in case of provider prompts
yes "1" | pacman --noconfirm -Syw "${filtered_packages[@]}" --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb

# Build remaining AUR packages from source (those not found in official or Chaotic-AUR repos)
for pkg in $(printf '%s\n' "${all_packages[@]}" | sort -u); do
  if ls "$offline_mirror_dir/$pkg"*.pkg.tar.zst &>/dev/null 2>&1; then
    continue
  fi
  echo "Building AUR package from source: $pkg"
  sudo -u builder git clone "https://aur.archlinux.org/$pkg.git" "/tmp/aur-build/$pkg" 2>/dev/null || continue
  pushd "/tmp/aur-build/$pkg" >/dev/null
  sudo -u builder makepkg -s --noconfirm --skippgpcheck 2>&1 || true
  find . -name '*.pkg.tar.zst' -exec cp -f {} "$offline_mirror_dir/" \; 2>/dev/null || true
  popd >/dev/null
done

repo-add --new "$offline_mirror_dir/offline.db.tar.gz" "$offline_mirror_dir/"*.pkg.tar.zst

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
