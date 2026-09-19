#!/usr/bin/env bash
# Build the AlwaysWork unattended installer ISO for Arch-family mini PCs
# (SYSTEM_SPEC §4.4). Run on Arch (or in the archlinux container, privileged)
# with `archiso` installed:
#
#   sudo image/arch/build.sh --out out/ [--provision provision.toml] [--ref main]
#
# The ISO boots straight into alwayswork-installer.service: it finds
# alwayswork/provision.toml (embedded at build time with --provision, or on
# any other FAT stick), wipes the disk it names, installs Arch with btrfs +
# snapper + systemd-boot, installs the agent from the bundled tarball, and
# reboots into a box that enrolls on first boot. Nothing is asked.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$PWD/out"; PROVISION=""; REF="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --provision) PROVISION="$2"; shift ;;
    --ref) REF="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$(id -u)" == "0" ]] || { echo "run as root (mkarchiso needs it)" >&2; exit 1; }
command -v mkarchiso >/dev/null || { echo "install archiso first: pacman -S archiso" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PROFILE="$WORK/profile"
cp -r /usr/share/archiso/configs/releng "$PROFILE"

# --- what the live system carries ---------------------------------------------
cat >> "$PROFILE/packages.x86_64" <<'PKGS'
btrfs-progs
dosfstools
jq
curl
PKGS
mkdir -p "$PROFILE/airootfs/root/alwayswork" "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants"
# The agent, from this checkout: the same tarball layout the control plane serves.
# The agent bundled into the image: a git ref of this repo (default main),
# or the working tree with --ref working.
if [[ "$REF" == "working" ]]; then
  tar -C "$REPO/.." --exclude=.git --exclude=node_modules --exclude=out -czf "$PROFILE/airootfs/root/alwayswork/alwayswork-agent.tar.gz" "$(basename "$REPO")"
else
  git -C "$REPO" archive --format=tar.gz --prefix=alwayswork-agent/ -o "$PROFILE/airootfs/root/alwayswork/alwayswork-agent.tar.gz" "$REF"
fi
cp "$HERE/installer.sh" "$PROFILE/airootfs/root/alwayswork/installer.sh"
chmod 0755 "$PROFILE/airootfs/root/alwayswork/installer.sh"
if [[ -n "$PROVISION" ]]; then
  cp "$PROVISION" "$PROFILE/airootfs/root/alwayswork/provision.toml"
  chmod 0600 "$PROFILE/airootfs/root/alwayswork/provision.toml"
fi
cat > "$PROFILE/airootfs/etc/systemd/system/alwayswork-installer.service" <<'UNIT'
[Unit]
Description=AlwaysWork unattended installer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/root/alwayswork/installer.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/alwayswork-installer.service "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/alwayswork-installer.service"
# The live ISO's own permissions table must know the new files.
cat >> "$PROFILE/profiledef.sh" <<'DEF'
file_permissions+=(
  ["/root/alwayswork/installer.sh"]="0:0:755"
  ["/root/alwayswork/provision.toml"]="0:0:600"
)
DEF
sed -i 's/^iso_name=.*/iso_name="alwayswork-arch"/; s/^iso_label=.*/iso_label="ALWAYSWORK"/; s/^iso_publisher=.*/iso_publisher="AlwaysWork"/' "$PROFILE/profiledef.sh"

mkdir -p "$OUT"
mkarchiso -v -w "$WORK/build" -o "$OUT" "$PROFILE"
echo "ISO in $OUT:"; ls -la "$OUT"/*.iso
