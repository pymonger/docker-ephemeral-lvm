#!/bin/sh -e
# This script will DESTROY ebs1|ephemeral0 and remount it for HySDS work dir.
# This script will DESTROY ebs2|ephemeral1 and remount it for Docker volume storage.

# update system first
yum update -y || true

# get user/group
if [[ -d "/home/ops" ]]; then
  user="ops"
  group="ops"
elif [[ -d "/home/ec2-user" ]]; then
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

# get disk for HySDS work dir (/data)
EPH0=`curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ephemeral0`
echo "ephemeral0: $EPH0"
if [[ ${EPH0:0:1} == "<" || ${EPH0} == "" ]] ; then
  EBS1=`curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ebs1`
  echo "ebs1: $EBS1"
  if [[ ${EBS1:0:1} == "<" || ${EBS1} == "" ]] ; then
    DATA_DEV="/dev/xvdb"
  else
    DATA_DEV="/dev/${EBS1}"
  fi
else
  DATA_DEV="/dev/${EPH0}"
fi
DATA_DEV=$(readlink -f $DATA_DEV) # resolve symlinks
echo "DATA_DEV: $DATA_DEV"

# get disk for Docker volume storage
EPH1=`curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ephemeral1`
echo "ephemeral1: $EPH1"
if [[ ${EPH1:0:1} == "<" || ${EPH1} == "" ]] ; then
  EBS2=`curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ebs2`
  echo "ebs2: $EBS2"
  if [[ ${EBS2:0:1} == "<" || ${EBS2} == "" ]] ; then
    DEV="/dev/xvdc"
  else
    DEV="/dev/${EBS2}"
  fi
else
  DEV="/dev/${EPH1}"
fi
DEV=$(readlink -f $DEV) # resolve symlinks
echo "DEV: $DEV"

# Setup Instance Store 1 for Docker volume storage
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

# Setup Instance Store 0 for HySDS work dir (/data) if mounted as /mnt
DATA_DIR="/data"
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

  # copy work and index style
  cp -rp ${DATA_DIR}.pristine/work ${DATA_DIR}/ || true

  # set permissions
  chown -R ${user}:${group} ${DATA_DIR} || true
fi

$start_docker
