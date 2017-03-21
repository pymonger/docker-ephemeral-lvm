#!/bin/sh -e
# This script will DESTROY /dev/xvdb|nvme0n1 and remount it for HySDS work dir.
# This script will DESTROY /dev/xvdc|nvme1n1 and remount it for Docker volume storage.
# It is intended for EC2 instances with 2 ephemeral SSD instance stores like 
# the c3.xlarge and i3.4xlarge instance types.

# get user/group
if [[ -d "/home/ec2-user" ]]; then
  user="ec2-user"
  group="ec2-user"
else
  user="ops"
  group="ops"
fi

# get docker daemon start/stop commands
if [[ -e "/bin/systemctl" ]]; then
  start_docker="systemctl start docker"
  stop_docker="systemctl stop docker"
else
  start_docker="service docker start"
  stop_docker="service docker stop"
fi

$stop_docker

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

$start_docker

# Setup Instance Store 0 for HySDS work dir (/data) if mounted as /mnt
DATA_DIR="/data"
if [[ -e "/dev/nvme0n1" ]]; then
  DATA_DEV="/dev/nvme0n1"
else
  DATA_DEV="/dev/xvdb"
fi
if [[ -e "$DATA_DEV" ]]; then
  # clean out /mnt, ${DATA_DIR} and ${DATA_DIR}.orig
  rm -rf /mnt/cache /mnt/jobs /mnt/tasks
  rm -rf ${DATA_DIR}/work/cache ${DATA_DIR}/work/jobs ${DATA_DIR}/work/tasks
  rm -rf ${DATA_DIR}.orig

  # backup ${DATA_DIR}/work and index style
  cp -rp ${DATA_DIR} ${DATA_DIR}.orig || true

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

  # mount as ${DATA_DIR}
  mkdir -p $DATA_DIR || true
  mount $DATA_DEV_ENC $DATA_DIR

  # set permissions
  chown -R ${user}:${group} ${DATA_DIR} || true

  # copy work and index style
  cp -rp ${DATA_DIR}.pristine/work ${DATA_DIR}/ || true
fi
