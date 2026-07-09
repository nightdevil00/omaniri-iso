# Omaniri ISO

The Omaniri ISO streamlines the installation of Omaniri. It includes the Omaniri Configurator as a front-end to archinstall and automatically launches the Omaniri Installer after base arch has been setup.

## Downloading the latest ISO

Download from [github.com/niraletter/omaniri/releases](https://github.com/niraletter/omaniri/releases).

## Prerequisites

- Docker installed and running
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

Output goes into `./release`. You can build from your local $OMANIRI_PATH for testing by using `--local-source`.

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

## Signing the ISO

Run `./bin/omaniri-iso-sign [gpg-user] [release/omaniri.iso]`.

## Full release of the ISO

Run `./bin/omaniri-iso-release VERSION` to create, test, and sign the ISO in one flow.