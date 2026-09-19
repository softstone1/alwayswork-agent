#!/usr/bin/env bash
# AlwaysWork unattended installer — runs in the live ISO (SYSTEM_SPEC §4.4).
#
# Finds alwayswork/provision.toml (embedded, or on any FAT stick), and with
# no questions: wipes the disk it names, installs Arch (btrfs subvolumes,
# snapper, systemd-boot, linux-lts), installs the AlwaysWork agent from the
# bundled tarball, enables its units, plants the provision file for the
# first boot, and reboots. The new box enrolls itself on first boot with
# the token in the file. A missing or malformed file stops the installer;
# a live shell stays available on tty2.
set -euo pipefail
log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

toml_get() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n1; }

find_provision() {
  [[ -f /root/alwayswork/provision.toml ]] && { echo /root/alwayswork/provision.toml; return 0; }
  local dev mnt
  for dev in $(lsblk -rno NAME,TYPE,RM 2>/dev/null | awk '$2=="part" && $3==1 {print "/dev/"$1}'); do
    mnt="$(mktemp -d)"
    if mount -o ro "$dev" "$mnt" 2>/dev/null; then
      if [[ -f "$mnt/alwayswork/provision.toml" ]]; then cp "$mnt/alwayswork/provision.toml" /root/provision.toml; umount "$mnt"; echo /root/provision.toml; return 0; fi
      umount "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
  done
  return 1
}

# Largest non-removable disk when the file says disk = "auto".
auto_disk() {
  lsblk -dbno NAME,SIZE,RM,TYPE | awk '$4=="disk" && $3==0 {print $2, "/dev/"$1}' | sort -rn | head -1 | awk '{print $2}'
}

log "AlwaysWork unattended installer"
for _ in $(seq 1 60); do curl -fsS -m 3 https://alwayswork.space/healthz >/dev/null 2>&1 && break; sleep 2; done
TOML="$(find_provision)" || die "no alwayswork/provision.toml found (embed one at build time or put it on a FAT stick); nothing installed"
DISK="$(toml_get "$TOML" disk)"; HOST="$(toml_get "$TOML" hostname)"; CONTROL="$(toml_get "$TOML" control_url)"; TOKEN="$(toml_get "$TOML" join_token)"
[[ -n "$TOKEN" ]] || die "provision.toml has no join_token"
[[ -n "$DISK" ]] || die "provision.toml must name the disk to wipe (disk = \"/dev/nvme0n1\" or \"auto\")"
[[ "$DISK" == "auto" ]] && DISK="$(auto_disk)"
[[ -b "$DISK" ]] || die "no such disk: $DISK"
[[ -n "$HOST" ]] || HOST="alwayswork-$(tr -dc 'a-z0-9' < /sys/class/dmi/id/product_serial 2>/dev/null | tail -c 6 || echo node)"
[[ -n "$CONTROL" ]] || CONTROL="https://alwayswork.space"
log "disk $DISK -> hostname $HOST -> $CONTROL"
sleep 5   # last chance to pull the plug

# --- partitions: 1 GiB ESP + btrfs root ------------------------------------
log "partitioning $DISK"
wipefs -af "$DISK" >/dev/null
sfdisk --quiet --wipe always "$DISK" <<'SF'
label: gpt
,1GiB,U
,,L
SF
udevadm settle
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then P1="${DISK}p1"; P2="${DISK}p2"; else P1="${DISK}1"; P2="${DISK}2"; fi
mkfs.fat -F32 -n ESP "$P1" >/dev/null
mkfs.btrfs -f -L alwayswork "$P2" >/dev/null
mount "$P2" /mnt
for sv in @ @home @var @snapshots; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
umount /mnt
OPTS="noatime,compress=zstd:3,space_cache=v2"
mount -o "$OPTS,subvol=@" "$P2" /mnt
mkdir -p /mnt/{home,var,.snapshots,boot}
mount -o "$OPTS,subvol=@home" "$P2" /mnt/home
mount -o "$OPTS,subvol=@var" "$P2" /mnt/var
mount -o "$OPTS,subvol=@snapshots" "$P2" /mnt/.snapshots
mount "$P1" /mnt/boot

# --- base system --------------------------------------------------------------
log "pacstrap"
pacstrap -K /mnt base linux-lts linux-firmware btrfs-progs snapper systemd-resolvconf networkmanager \
  sudo git curl jq openssl age sops restic ufw snap-pac >/dev/null
genfstab -U /mnt >> /mnt/etc/fstab

log "configuring the target"
echo "$HOST" > /mnt/etc/hostname
ln -sf /usr/share/zoneinfo/UTC /mnt/etc/localtime
echo "en_US.UTF-8 UTF-8" > /mnt/etc/locale.gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
mkdir -p /mnt/opt /mnt/var/lib/alwayswork /mnt/etc/alwayswork
tar -xzf /root/alwayswork/alwayswork-agent.tar.gz -C /mnt/opt
mv /mnt/opt/alwayswork-agent* /mnt/opt/alwayswork 2>/dev/null || true
cp "$TOML" /mnt/var/lib/alwayswork/provision.toml; chmod 0600 /mnt/var/lib/alwayswork/provision.toml

arch-chroot /mnt /bin/bash -euo pipefail <<'CHROOT'
locale-gen >/dev/null
systemctl enable NetworkManager systemd-resolved systemd-timesyncd >/dev/null 2>&1
# Bootloader: systemd-boot with the LTS kernel; a fallback entry keeps a way back.
bootctl install >/dev/null
ROOT_UUID="$(findmnt -no UUID /)"
cat > /boot/loader/loader.conf <<'LC'
default alwayswork.conf
timeout 2
editor no
LC
cat > /boot/loader/entries/alwayswork.conf <<LE
title   AlwaysWork (linux-lts)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts.img
options root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet
LE
cat > /boot/loader/entries/alwayswork-fallback.conf <<LE
title   AlwaysWork (linux-lts, fallback initramfs)
linux   /vmlinuz-linux-lts
initrd  /initramfs-linux-lts-fallback.img
options root=UUID=${ROOT_UUID} rootflags=subvol=@ rw
LE
# Snapshots of / for aw update's probation and rollback.
umount /.snapshots 2>/dev/null || true; rmdir /.snapshots 2>/dev/null || true
snapper --no-dbus -c root create-config / >/dev/null 2>&1 || true
mount -a 2>/dev/null || true
# The agent: link the CLI, install its units, no enrolment yet (first boot does it).
ln -sf /opt/alwayswork/bin/alwayswork /usr/local/bin/alwayswork
ln -sf /opt/alwayswork/bin/alwayswork /usr/local/bin/aw
chmod +x /opt/alwayswork/bin/alwayswork /opt/alwayswork/install.sh
find /opt/alwayswork -name '*.sh' -exec chmod +x {} +
/opt/alwayswork/install.sh --from /opt/alwayswork --skip-deps --no-alias >/dev/null 2>&1 || true
CHROOT

# First boot: enrol from the planted provision file, then delete it.
cat > /mnt/etc/systemd/system/alwayswork-firstboot.service <<'UNIT'
[Unit]
Description=AlwaysWork first boot: enrol from the provisioning file
After=network-online.target time-sync.target
Wants=network-online.target
ConditionPathExists=/var/lib/alwayswork/provision.toml

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -e; T=/var/lib/alwayswork/provision.toml; g(){ sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$T" | head -n1; }; ALWAYSWORK_AUTO_ENROLL=1 /opt/alwayswork/install.sh --yes --from /opt/alwayswork --skip-deps --control "$(g control_url)" --token "$(g join_token)" $( [ -n "$(g profile)" ] && printf -- "--profile %s" "$(g profile)" ) && shred -u "$T"'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/alwayswork-firstboot.service /mnt/etc/systemd/system/multi-user.target.wants/alwayswork-firstboot.service 2>/dev/null || true
mkdir -p /mnt/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/alwayswork-firstboot.service /mnt/etc/systemd/system/multi-user.target.wants/alwayswork-firstboot.service

log "done: $HOST on $DISK; rebooting into the installed system"
sync; umount -R /mnt
systemctl reboot
