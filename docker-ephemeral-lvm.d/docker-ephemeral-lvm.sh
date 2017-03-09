#!/bin/sh -e
# This script will DESTROY /dev/xvdb|nvme0n1 and remount it for HySDS work dir.
# This script will DESTROY /dev/xvdc|nvme1n1 and remount it for Docker volume storage.
# It is intended for EC2 instances with 2 ephemeral SSD instance stores like 
# the c3.xlarge and i3.4xlarge instance types.

systemctl stop docker || true

# Setup Instance Store 1 for Docker volume storage
if [[ -e "/dev/nvme1n1" ]]; then
  DEV="/dev/nvme1n1"
else
  DEV="/dev/xvdc"
fi
if [[ -e "$DEV" ]]; then
  # clean out docker
  rm -rf /var/lib/docker

  # unmount block device if not already
  umount $DEV 2>/dev/null || true

  # remove volume group
  vgremove -ff vg-docker || true

  # remove physical volume
  pvremove -ff $DEV || true

  # install cryptsetup
  yum install -y cryptsetup || true

  # generate random passphrase
  PASSPHRASE=`hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random`

  # format the ephemeral volume with selected cipher
  echo $PASSPHRASE | cryptsetup luksFormat -c twofish-xts-plain64 -s 512 --key-file=- $DEV

  # open the encrypted volume to a mapped device
  echo $PASSPHRASE | cryptsetup luksOpen --key-file=- $DEV ephemeral-encrypted

  # set name of mapped device
  DEV_ENC="/dev/mapper/ephemeral-encrypted"

  # determine 75% of volume size to be used for docker data
  DATA_SIZE=`lsblk -b $DEV | grep disk | awk '{printf "%.0f\n", $4/1024^3*.75}'`

  # create physical volume and volume group for docker
  pvcreate -ff $DEV_ENC
  vgcreate -ff  vg-docker $DEV_ENC

  # reconfigure docker storage for devicemapper
  echo "STORAGE_DRIVER=devicemapper" > /etc/sysconfig/docker-storage-setup
  echo "VG=vg-docker" >> /etc/sysconfig/docker-storage-setup
  echo "DATA_SIZE=${DATA_SIZE}G" >> /etc/sysconfig/docker-storage-setup
  rm -f /etc/sysconfig/docker-storage
  docker-storage-setup

  # update maximum size for image or container
  sed -i 's# "# --storage-opt dm.basesize=100GB "#' /etc/sysconfig/docker-storage
fi

systemctl start docker

# Setup Instance Store 0 for HySDS work dir (/data) if mounted as /mnt
DATA_DIR="/data"
if [[ -e "/dev/nvme0n1" ]]; then
  DATA_DEV="/dev/nvme0n1"
else
  DATA_DEV="/dev/xvdb"
fi
if [[ -e "$DATA_DEV" ]]; then
  # clean out /mnt, /data and /data.orig
  rm -rf /mnt/cache /mnt/jobs /mnt/tasks
  rm -rf /data/work/cache /data/work/jobs /data/work/tasks
  rm -rf /data.orig

  # backup /data/work and index style
  cp -rp /data /data.orig || true

  # unmount block device if not already
  umount $DATA_DEV 2>/dev/null || true

  # install cryptsetup
  yum install -y cryptsetup || true

  # generate random passphrase
  PASSPHRASE=`hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random`

  # format the ephemeral volume with selected cipher
  echo $PASSPHRASE | cryptsetup luksFormat -c twofish-xts-plain64 -s 512 --key-file=- $DATA_DEV

  # open the encrypted volume to a mapped device
  echo $PASSPHRASE | cryptsetup luksOpen --key-file=- $DATA_DEV ephemeral-encrypted-data

  # set name of mapped device
  DATA_DEV_ENC="/dev/mapper/ephemeral-encrypted-data"

  # format XFS
  mkfs.xfs -f $DATA_DEV_ENC

  # mount as /data
  mount $DATA_DEV_ENC $DATA_DIR

  # set permissions
  chown -R ops:ops /data || true

  # copy work and index style
  cp -rp /data.orig/work /data/ || true
fi
