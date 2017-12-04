#!/bin/sh -e
# This script will DESTROY the first ephemeral/EBS volume and remount it for HySDS work dir.
# This script will DESTROY the second ephemeral/EBS volume and remount it for Docker volume storage.

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

# get ephemeral storage devices
EPH_BLK_DEVS=( `curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ | grep ^ephemeral | sort` )
EPH_BLK_DEVS_CNT=${#EPH_BLK_DEVS[@]}
echo "Number of ephemeral storage devices: $EPH_BLK_DEVS_CNT"

# get EBS block devices
EBS_BLK_DEVS=( `curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/ | grep ^ebs | sort` )
EBS_BLK_DEVS_CNT=${#EBS_BLK_DEVS[@]}
echo "Number of EBS block devices: $EBS_BLK_DEVS_CNT"

# delegate devices for HySDS work dir and docker storage volumes
if [ "$EPH_BLK_DEVS_CNT" -ge 2 ]; then
  DATA_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[0]})
  DOCKER_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[1]})
elif [ "$EPH_BLK_DEVS_CNT" -eq 1 ]; then
  DATA_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[0]})
  if [ "$EBS_BLK_DEVS_CNT" -ge 1 ]; then
    DOCKER_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
  else
    DOCKER_DEV=/dev/xvdc
  fi
else
  if [ "$EBS_BLK_DEVS_CNT" -ge 2 ]; then
    DATA_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
    DOCKER_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[1]})
  elif [ "$EBS_BLK_DEVS_CNT" -eq 1 ]; then
    DATA_DEV=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
    DOCKER_DEV=/dev/xvdc
  else
    DATA_DEV=/dev/xvdb
    DOCKER_DEV=/dev/xvdc
  fi
fi

# resolve symlinks
DATA_DEV=$(readlink -f $DATA_DEV)
DOCKER_DEV=$(readlink -f $DOCKER_DEV)

# i3 instances utilizing NVMe will have incorrect mount in EC2 metadata; handle this case
if [[ ! -e "$DATA_DEV" && -e "/dev/nvme0n1" ]]; then
  DATA_DEV=/dev/nvme0n1
fi
if [[ ! -e "$DOCKER_DEV" && -e "/dev/nvme1n1" ]]; then
  DOCKER_DEV=/dev/nvme1n1
fi

# log devices
echo "DATA_DEV: $DATA_DEV"
echo "DOCKER_DEV: $DOCKER_DEV"

# Setup docker volume storage
if [[ -e "$DOCKER_DEV" ]]; then
  # clean out docker
  rm -rf /var/lib/docker

  # unmount block device if not already
  umount $DOCKER_DEV 2>/dev/null || true

  # remove volume group
  vgremove -ff vg-docker || true

  # remove physical volume
  pvremove -ff $DOCKER_DEV || true

  # install cryptsetup
  yum install -y cryptsetup || true

  # generate random passphrase
  PASSPHRASE=`hexdump -n 16 -e '4/4 "%08X" 1 "\n"' /dev/random`

  # format the ephemeral volume with selected cipher
  echo $PASSPHRASE | cryptsetup luksFormat -c twofish-xts-plain64 -s 512 --key-file=- $DOCKER_DEV

  # open the encrypted volume to a mapped device
  echo $PASSPHRASE | cryptsetup luksOpen --key-file=- $DOCKER_DEV ephemeral-encrypted

  # set name of mapped device
  DOCKER_DEV_ENC="/dev/mapper/ephemeral-encrypted"

  # determine 75% of volume size to be used for docker data
  DATA_SIZE=`lsblk -b $DOCKER_DEV | grep disk | awk '{printf "%.0f\n", $4/1024^3*.75}'`

  # create physical volume and volume group for docker
  pvcreate -ff $DOCKER_DEV_ENC
  vgcreate -ff  vg-docker $DOCKER_DEV_ENC

  # reconfigure docker storage for devicemapper
  echo "STORAGE_DRIVER=devicemapper" > /etc/sysconfig/docker-storage-setup
  echo "VG=vg-docker" >> /etc/sysconfig/docker-storage-setup
  echo "DATA_SIZE=${DATA_SIZE}G" >> /etc/sysconfig/docker-storage-setup
  rm -f /etc/sysconfig/docker-storage
  docker-storage-setup

  # update maximum size for image or container
  sed -i 's# "# --storage-opt dm.basesize=100GB "#' /etc/sysconfig/docker-storage
fi

# Setup HySDS work dir (/data) if mounted as /mnt
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
