#!/usr/bin/env bash
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo >&2; printf '\033[1;36m=== %s ===\033[0m\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: sudo bash setup.sh [--rotate-passwords] <office_iface> <legacy_iface> <disk_name>
Example: sudo bash setup.sh enp2s0 enp10s0 nvme0n2

Rerunning is safe: the disk is only partitioned/formatted on first setup, and
Samba passwords are kept unless you pass --rotate-passwords.
EOF
}

[[ $EUID -eq 0 ]] || die "Script must be run as root"

rotate_passwords=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --rotate-passwords) rotate_passwords=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage; die "Unknown flag: $1" ;;
        *) break ;;
    esac
done

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

office_iface=$1
legacy_iface=$2
disk_name=$3

step "Validating arguments"

ip -o link show "$office_iface" >/dev/null 2>&1 || die "No such network interface: $office_iface"
ok "Office interface found: $office_iface"

ip -o link show "$legacy_iface" >/dev/null 2>&1 || die "No such network interface: $legacy_iface"
ok "Legacy interface found: $legacy_iface"

[[ -b /dev/$disk_name ]] || die "No such block device: /dev/$disk_name"
ok "Target disk found: /dev/$disk_name"

# NVMe/mmc disks end in a digit and use a 'p' separator (nvme0n2 -> nvme0n2p1);
# scsi/sata disks don't (sda -> sda1).
if [[ $disk_name =~ [0-9]$ ]]; then
    partition_path="/dev/${disk_name}p1"
else
    partition_path="/dev/${disk_name}1"
fi
log "Partition will be: $partition_path"

step "Installing required packages"
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
dnf install -y samba samba-client ntfs-3g ntfsprogs inotify-tools net-tools \
               parted policycoreutils-python-utils firewalld

# Skip the destructive partition/format step if the target partition already
# holds an NTFS filesystem. Lets the script be rerun without wiping /samba.
needs_format=1
if [[ -b $partition_path ]]; then
    existing_fs=$(blkid -s TYPE -o value "$partition_path" 2>/dev/null || true)
    if [[ $existing_fs == "ntfs" ]]; then
        needs_format=0
    fi
fi

if (( needs_format )); then
    step "Creating NTFS partition on /dev/$disk_name"

    if mountpoint -q /samba; then
        log "/samba is currently mounted, unmounting..."
        umount /samba
    fi

    log "Writing GPT label and primary NTFS partition"
    parted -s "/dev/$disk_name" mklabel gpt
    parted -s "/dev/$disk_name" mkpart primary ntfs 0% 100%

    partprobe "/dev/$disk_name" || true
    udevadm settle || true

    # partprobe is not always instant on every controller; wait briefly for the
    # device node to appear before formatting.
    for _ in 1 2 3 4 5; do
        [[ -b $partition_path ]] && break
        sleep 1
    done
    [[ -b $partition_path ]] || die "Partition $partition_path did not appear after partprobe"

    log "Formatting $partition_path as NTFS"
    mkfs.ntfs -f "$partition_path"
else
    step "Reusing existing NTFS partition at $partition_path"
fi

mkdir -p /samba

step "Ensuring /samba is in /etc/fstab and mounted"
fstab_line="$partition_path /samba ntfs defaults,noexec,uid=nobody,gid=nobody,fmask=0111,dmask=0000,context=system_u:object_r:samba_share_t:s0 0 0"

if ! grep -qxF "$fstab_line" /etc/fstab; then
    if grep -qE '[[:space:]]/samba[[:space:]]' /etc/fstab; then
        log "Replacing stale /samba entry in /etc/fstab (backup at /etc/fstab.bak)"
        sed -i.bak -E '/[[:space:]]\/samba[[:space:]]/d' /etc/fstab
    else
        log "Adding /samba entry to /etc/fstab"
    fi
    echo "$fstab_line" >> /etc/fstab
    systemctl daemon-reload
fi

if ! mountpoint -q /samba; then
    log "Mounting /samba"
    mount /samba
fi
mountpoint -q /samba || die "Failed to mount /samba"
ok "/samba mounted from $partition_path"

step "Creating share folders"
mkdir -p /samba/legacy /samba/office

step "Writing Samba configurations"
cat > /etc/samba/legacy.conf <<EOF
[global]
workgroup = WORKGROUP
security = user
server min protocol = NT1
server max protocol = SMB3
bind interfaces only = yes
interfaces = $legacy_iface
acl allow execute always = no
map archive = no
map system = no
map hidden = no
store dos attributes = yes
printing = bsd
printcap name = /dev/null
disable spoolss = yes
pid directory = /run/samba-legacy
state directory = /var/lib/samba-legacy
private dir = /var/lib/samba-legacy/private
lock directory = /var/lib/samba-legacy/lock
cache directory = /var/cache/samba-legacy

[legacy]
path = /samba/legacy
valid users = legacy_user
read only = no
browsable = yes
writable = yes
create mask = 0660
force create mode = 0660
directory mask = 0770
force directory mode = 0770
EOF

cat > /etc/samba/office.conf <<EOF
[global]
workgroup = WORKGROUP
security = user
server min protocol = SMB3
server max protocol = SMB3
bind interfaces only = yes
interfaces = $office_iface
acl allow execute always = no
map archive = no
map system = no
map hidden = no
store dos attributes = yes
printing = bsd
printcap name = /dev/null
disable spoolss = yes
pid directory = /run/samba-office
state directory = /var/lib/samba-office
private dir = /var/lib/samba-office/private
lock directory = /var/lib/samba-office/lock
cache directory = /var/cache/samba-office

[office]
path = /samba/office
valid users = office_user
read only = no
browsable = yes
writable = yes
create mask = 0660
force create mode = 0660
directory mask = 0770
force directory mode = 0770
EOF

step "Preparing Samba runtime directories and SELinux contexts"
for instance in legacy office; do
    mkdir -p "/var/lib/samba-${instance}/private" \
             "/var/cache/samba-${instance}" \
             "/var/lock/samba-${instance}" \
             "/run/samba-${instance}"

    # /run/... is tracked as /var/run/... by semanage due to the equivalency rule.
    # `-a` fails if the context already exists; fall back to `-m` so re-runs succeed.
    for path_type in \
        "samba_var_t:/var/lib/samba-${instance}(/.*)?" \
        "samba_var_t:/var/cache/samba-${instance}(/.*)?" \
        "samba_var_t:/var/lock/samba-${instance}(/.*)?" \
        "smbd_var_run_t:/var/run/samba-${instance}(/.*)?"; do
        selinux_type=${path_type%%:*}
        selinux_path=${path_type#*:}
        semanage fcontext -a -t "$selinux_type" "$selinux_path" 2>/dev/null || \
            semanage fcontext -m -t "$selinux_type" "$selinux_path"
    done
done
restorecon -R /var/lib/samba* /var/cache/samba* /var/lock/samba* /run/samba*

step "Creating Samba systemd services"
for instance in legacy office; do
    cat > "/etc/systemd/system/samba-${instance}.service" <<EOF
[Unit]
Description=Samba Daemon for ${instance} network
After=network.target

[Service]
Type=notify
NotifyAccess=all
ExecStart=/usr/sbin/smbd --foreground --no-process-group -s /etc/samba/${instance}.conf
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=16384
PIDFile=/run/samba-${instance}/smbd.pid

[Install]
WantedBy=multi-user.target
EOF
done

systemctl daemon-reload
systemctl enable --now samba-legacy
systemctl enable --now samba-office

step "Configuring Samba users"

# Subshell disables pipefail so `tr ... | head -c 32` doesn't trip set -e when
# `head` closes the pipe and `tr` exits via SIGPIPE.
gen_password() (
    set +o pipefail
    LC_ALL=C tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 32
)

ensure_smb_user() {
    local instance=$1 user=$2
    local conf="/etc/samba/${instance}.conf"
    local pw

    id "$user" >/dev/null 2>&1 || useradd -M -s /sbin/nologin "$user"

    if pdbedit -L -s "$conf" -u "$user" >/dev/null 2>&1; then
        if (( rotate_passwords )); then
            pw=$(gen_password)
            echo -e "${pw}\n${pw}" | smbpasswd -c "$conf" -s "$user" >/dev/null
            log "Rotated Samba password for $user"
            printf '%s' "$pw"
        else
            log "$user already has a Samba password, keeping it (pass --rotate-passwords to change)"
        fi
    else
        pw=$(gen_password)
        echo -e "${pw}\n${pw}" | smbpasswd -c "$conf" -s -a "$user" >/dev/null
        smbpasswd -c "$conf" -e "$user" >/dev/null
        log "Created Samba user $user"
        printf '%s' "$pw"
    fi
}

legacy_password=$(ensure_smb_user legacy legacy_user)
office_password=$(ensure_smb_user office office_user)

step "Configuring firewall"
systemctl enable --now firewalld

firewall-cmd --permanent --new-zone=legacy_net 2>/dev/null || log "Zone legacy_net already exists"
firewall-cmd --permanent --new-zone=office_net 2>/dev/null || log "Zone office_net already exists"

firewall-cmd --permanent --zone=legacy_net --change-interface="$legacy_iface"
firewall-cmd --permanent --zone=office_net --change-interface="$office_iface"

firewall-cmd --permanent --zone=legacy_net --add-service=samba
firewall-cmd --permanent --zone=office_net --add-service=samba

firewall-cmd --reload

echo
ok "Setup complete."
if [[ -n $legacy_password || -n $office_password ]]; then
    echo
    echo "STORE PASSWORDS BELOW, THEY WILL BE USED FOR ACCESSING SHARES"
    [[ -n $legacy_password ]] && echo "Legacy: username = legacy_user, password = $legacy_password"
    [[ -n $office_password ]] && echo "Office: username = office_user, password = $office_password"
fi
