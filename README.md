# Omaniri ISO

The Omaniri ISO streamlines the installation of Omaniri. It includes the Omaniri Configurator as a front-end to archinstall, boots straight into the Omaniri live environment, and automatically launches the Omaniri Installer after base Arch has been set up.

The build creates an offline package mirror inside the ISO. Official Arch packages are downloaded with pacman, selected Chaotic-AUR packages are downloaded from Chaotic-AUR, and the remaining AUR packages are built during ISO creation so the installed system does not need internet access for those packages later.

## Downloading the latest ISO

Download from [github.com/niraletter/omaniri-iso/releases](https://github.com/niraletter/omaniri-iso/releases).

## Prerequisites

- Docker installed and running, available to your user without `sudo`
- `git` installed

To install Docker:

**Arch:**
```bash
sudo pacman -S docker git
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

**Debian/Ubuntu:**
```bash
sudo apt update && sudo apt install docker.io git
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

**Fedora:**
```bash
sudo dnf install docker git
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

Then log out and back in for the group change to take effect.

## Creating the ISO

```bash
git clone https://github.com/niraletter/omaniri-iso
cd omaniri-iso
git submodule update --init --recursive
./bin/omaniri-iso-make
```

Output goes into `./release`. The final ISO is named with the Omaniri version when available, for example `omaniri-YYYY.MM.DD-x86_64-v1.0.iso`.

Build options:

- `--local-source` - use your local `$OMANIRI_PATH` instead of cloning Omaniri from GitHub
- `--no-cache` - do not reuse the dated offline package cache under `~/.cache/omaniri`
- `--no-boot-offer` - skip the prompt to boot the ISO after the build

The ISO metadata is set so VM managers can detect it as Arch Linux, while the visible ISO filename remains Omaniri-branded.

## Package Sources

The builder combines packages from these sources:

- Official Arch repos: archiso releng packages, `builder/archinstall.packages`, and Omaniri package lists from the installer repo
- AUR packages: `builder/aur.packages`
- Chaotic-AUR binary packages: `builder/chaotic.packages`

Use `builder/aur.packages` for packages that are not available in the official Arch repos and need to be built during ISO creation. Keep `builder/chaotic.packages` scoped to packages intentionally pulled from Chaotic-AUR.

### Environment Variables

You can customize the repositories used during the build process by passing in variables:

- `OMANIRI_INSTALLER_REPO` - GitHub repository for the installer (default: `niraletter/omaniri`)
- `OMANIRI_INSTALLER_REF` - Git ref (branch/tag) for the installer (default: `main`)

Example usage:
```bash
OMANIRI_INSTALLER_REPO="myuser/omaniri-fork" OMANIRI_INSTALLER_REF="some-feature" ./bin/omaniri-iso-make
```

## Testing the ISO

Run `./bin/omaniri-iso-boot [release/omaniri.iso]`.

The QEMU helper disables the boot menu and boots the ISO directly.

## Signing the ISO

Run `./bin/omaniri-iso-sign [gpg-user] [release/omaniri.iso]`.

## Full release of the ISO

Run `./bin/omaniri-iso-release VERSION` to create, test, and sign the ISO in one flow.
