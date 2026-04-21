if [[ $USER != "root" ]]
then
    echo "Script must be run with root user"
    exit
fi

if [[ -z $1 ]] || [[ -z $2 ]] || [[ -z $3 ]]
then
    echo "Usage: sudo bash setup.sh office_network_interface_name legacy_network_interface_name disk_name_for_smb_share"
    echo "Example: sudo bash setup.sh enp2s0 enp10s0 nvme0n2"
    exit
fi

office_network_interface_name=$1
legacy_network_interface_name=$2
disk_name_for_smb_share=$3

if ! ip addr | grep -q $office_network_interface_name 
then
    echo "No such network interface: $office_network_interface_name"
    exit
fi

if ! ip addr | grep -q $legacy_network_interface_name 
then
    echo "No such network interface: $legacy_network_interface_name"
    exit
fi

if ! lsblk | awk '{ print $1 }' | grep -v '─' | grep -q $disk_name_for_smb_share 
then
    echo "No such disk available: $disk_name_for_smb_share"
    exit
fi

ip_office_network_interface=$(ip addr | grep $office_network_interface_name | grep inet | awk '{ print $2 }')
ip_legacy_network_interface=$(ip addr | grep $legacy_network_interface_name | grep inet | awk '{ print $2 }')

# install required packages
dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
dnf install -y samba samba-client ntfs-3g ntfsprogs inotify-tools net-tools parted policycoreutils-python-utils firewalld

# create NTFS partition
umount /dev/$disk_name_for_smb_share
parted -s /dev/$disk_name_for_smb_share mklabel gpt
parted -s /dev/$disk_name_for_smb_share mkpart primary ntfs 0% 100%
mkfs.ntfs -f /dev/$disk_name_for_smb_share
mkdir -p /samba

# edit fstab for mounting NTFS partition
if ! cat /etc/fstab | grep -q $disk_name_for_smb_share
then
    echo "Partition name is not in /etc/fstab, adding..."
    echo "/dev/$disk_name_for_smb_share /samba ntfs defaults,noexec,uid=nobody,gid=nobody,fmask=0111,dmask=0000,context=system_u:object_r:samba_share_t:s0 0 0" >> /etc/fstab
    systemctl daemon-reload
fi

mount -a

if ! df -Th | grep -q "^/dev/nvme0n2.*/samba$"
then
    echo "Mounting NTFS partition has failed, exiting..."
    exit
fi

# create share folders
mkdir -p /samba/legacy/
mkdir -p /samba/office/

# Creating Samba services
echo """
[global]
workgroup = WORKGROUP
security = user
server min protocol = NT1
server max protocol = SMB3
bind interfaces only = yes
interfaces = $legacy_network_interface_name
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
force directory mode = 0770""" > /etc/samba/legacy.conf

echo """
[global]
workgroup = WORKGROUP
security = user
server min protocol = SMB3
server max protocol = SMB3
bind interfaces only = yes
interfaces = $office_network_interface_name
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
force directory mode = 0770""" > /etc/samba/office.conf

mkdir -p /var/lib/samba-legacy/private /var/cache/samba-legacy /var/lock/samba-legacy /run/samba-legacy
mkdir -p /var/lib/samba-office/private /var/cache/samba-office /var/lock/samba-office /run/samba-office

semanage fcontext -a -t samba_var_t "/var/lib/samba-legacy(/.*)?"
semanage fcontext -a -t samba_var_t "/var/cache/samba-legacy(/.*)?"
semanage fcontext -a -t samba_var_t "/var/lock/samba-legacy(/.*)?"
semanage fcontext -a -t smbd_var_run_t "/run/samba-legacy(/.*)?"

semanage fcontext -a -t samba_var_t "/var/lib/samba-office(/.*)?"
semanage fcontext -a -t samba_var_t "/var/cache/samba-office(/.*)?"
semanage fcontext -a -t samba_var_t "/var/lock/samba-office(/.*)?"
semanage fcontext -a -t smbd_var_run_t "/run/samba-office(/.*)?"

restorecon -Rv /var/lib/samba* /var/cache/samba* /var/lock/samba* /run/samba*

echo """[Unit]
Description=Samba Daemon for office network
After=network.target

[Service]
Type=notify
NotifyAccess=all
ExecStart=/usr/sbin/smbd --foreground --no-process-group -s /etc/samba/office.conf
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=16384
PIDFile=/run/samba-office/smbd.pid

[Install]
WantedBy=multi-user.target""" > /etc/systemd/system/samba-office.service

echo """[Unit]
Description=Samba Daemon for legacy network
After=network.target

[Service]
Type=notify
NotifyAccess=all
ExecStart=/usr/sbin/smbd --foreground --no-process-group -s /etc/samba/legacy.conf
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=16384
PIDFile=/run/samba-legacy/smbd.pid

[Install]
WantedBy=multi-user.target""" > /etc/systemd/system/samba-legacy.service

systemctl daemon-reload
systemctl enable --now samba-legacy
systemctl enable --now samba-office

# creating random passwords for smb users
legacy_password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 32)
office_password=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 32)

# create users for each share
useradd -M -s /sbin/nologin office_user
useradd -M -s /sbin/nologin legacy_user

echo -e "$legacy_password\n$legacy_password" | smbpasswd -c /etc/samba/legacy.conf -a legacy_user
smbpasswd -c /etc/samba/legacy.conf -e legacy_user
echo -e "$office_password\n$office_password" | smbpasswd -c /etc/samba/office.conf -a office_user
smbpasswd -c /etc/samba/office.conf -e office_user

# Configuring firewall
systemctl enable --now firewalld

firewall-cmd --permanent --new-zone=legacy_net
firewall-cmd --permanent --new-zone=office_net

firewall-cmd --permanent --zone=legacy_net --change-interface=$legacy_network_interface_name
firewall-cmd --permanent --zone=office_net --change-interface=$office_network_interface_name

firewall-cmd --permanent --zone=legacy_net --add-service=samba
firewall-cmd --permanent --zone=office_net --add-service=samba

firewall-cmd --reload

echo
echo "STORE PASSWORDS BELOW, THEY WILL BE USED FOR ACCESSING SHARES"
echo "Legacy: username = legacy_user, password = $legacy_password"
echo "Office: username = office_user, password = $office_password"
