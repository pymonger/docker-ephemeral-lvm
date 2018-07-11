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
  reset_docker="systemctl reset-failed docker"
  start_docker="systemctl start docker"
  stop_docker="systemctl stop docker"
else
  reset_docker=""
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

# set devices
if [ "$EPH_BLK_DEVS_CNT" -ge 2 ]; then
  DEV1=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[0]})
  DEV2=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[1]})
elif [ "$EPH_BLK_DEVS_CNT" -eq 1 ]; then
  DEV1=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EPH_BLK_DEVS[0]})
  if [ "$EBS_BLK_DEVS_CNT" -ge 1 ]; then
    DEV2=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
  else
    DEV2=/dev/xvdc
  fi
else
  if [ "$EBS_BLK_DEVS_CNT" -ge 2 ]; then
    DEV1=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
    DEV2=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[1]})
  elif [ "$EBS_BLK_DEVS_CNT" -eq 1 ]; then
    DEV1=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]})
    DEV2=/dev/xvdc
  else
    DEV1=/dev/xvdb
    DEV2=/dev/xvdc
  fi
fi

# resolve symlinks
DEV1=$(readlink -f $DEV1)
DEV2=$(readlink -f $DEV2)

# resolve NVMe devices
if [[ ! -e "$DEV1" && ! -e "$DEV2" ]]; then
  yum install -y nvme-cli || true
  NVME_NODES=( `nvme list | grep '^/dev/' | awk '{print $1}' | sort` )
  NVME_NODES_CNT=${#NVME_NODES[@]}
  if [[ "${NVME_NODES_CNT}" -gt 0 ]]; then
    # get root device and node
    ROOT_DEV=$(df -hv / | grep '^/dev' | awk '{print $1}')
    for nvme_dev in `nvme list | grep -v ${ROOT_DEV} | grep '^/dev/' | awk '{print $1}' | sort`; do
      if [[ $ROOT_DEV = ${nvme_dev}* ]]; then
        ROOT_NODE=$nvme_dev
      fi
    done

    # get instance storage devices
    if [ -z ${ROOT_NODE+x} ]; then
        NVME_EPH_BLK_DEVS=( `nvme list |  grep '^/dev/' | grep -i 'Instance Storage' | awk '{print $1}' | sort` )
    else
        NVME_EPH_BLK_DEVS=( `nvme list | grep -v ${ROOT_NODE} | grep '^/dev/' | grep -i 'Instance Storage' | awk '{print $1}' | sort` )
    fi
    NVME_EPH_BLK_DEVS_CNT=${#NVME_EPH_BLK_DEVS[@]}
    echo "Number of NVMe local storage block devices: $NVME_EPH_BLK_DEVS_CNT"

    # get EBS devices
    if [ -z ${ROOT_NODE+x} ]; then
        NVME_EBS_BLK_DEVS=( `nvme list |  grep '^/dev/' | grep 'Elastic Block Store' | awk '{print $1}' | sort` )
    else
        NVME_EBS_BLK_DEVS=( `nvme list | grep -v ${ROOT_NODE} | grep '^/dev/' | grep 'Elastic Block Store' | awk '{print $1}' | sort` )
    fi
    NVME_EBS_BLK_DEVS_CNT=${#NVME_EBS_BLK_DEVS[@]}
    echo "Number of NVMe EBS block devices: $NVME_EBS_BLK_DEVS_CNT"
  
    # assign devices
    if [ "$NVME_EPH_BLK_DEVS_CNT" -ge 2 ]; then
      DEV1=${NVME_EPH_BLK_DEVS[0]}
      DEV2=${NVME_EPH_BLK_DEVS[1]}
    elif [ "$NVME_EPH_BLK_DEVS_CNT" -eq 1 ]; then
      DEV1=${NVME_EPH_BLK_DEVS[0]}
      if [ "$NVME_EBS_BLK_DEVS_CNT" -ge 1 ]; then
        DEV2=${NVME_EBS_BLK_DEVS[0]}
      else
        if [ "$EBS_BLK_DEVS_CNT" -ge 1 ]; then
          DEV2=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]} | sed 's/^sd/xvd/')
        else
          DEV2=/dev/xvdb
        fi
      fi
    else
      if [ "$NVME_EBS_BLK_DEVS_CNT" -ge 2 ]; then
        DEV1=${NVME_EBS_BLK_DEVS[0]}
        DEV2=${NVME_EBS_BLK_DEVS[1]}
      elif [ "$NVME_EBS_BLK_DEVS_CNT" -eq 1 ]; then
        DEV1=${NVME_EBS_BLK_DEVS[0]}
        if [ "$EBS_BLK_DEVS_CNT" -ge 1 ]; then
          DEV2=/dev/$(curl -s http://169.254.169.254/latest/meta-data/block-device-mapping/${EBS_BLK_DEVS[0]} | sed 's/^sd/xvd/')
        else
          DEV2=/dev/xvdb
        fi
      else
        DEV1=/dev/xvdb
        DEV2=/dev/xvdc
      fi
    fi
  else
    DEV1=/dev/xvdb
    DEV2=/dev/xvdc
  fi
fi
# get sizes
DEV1_SIZE=$(blockdev --getsize64 $DEV1)
DEV2_SIZE=$(blockdev --getsize64 $DEV2)

# log device sizes
echo "DEV1: $DEV1 $DEV1_SIZE"
echo "DEV2: $DEV2 $DEV2_SIZE"

# delegate devices for HySDS work dir and docker storage volumes; 
# if only one ephemeral disk, use for docker; # otherwise larger 
# one is for HySDS work dir
if [[ "$EPH_BLK_DEVS_CNT" -eq 1 || "$NVME_EPH_BLK_DEVS_CNT" -eq 1 ]]; then
  DOCKER_DEV=$DEV1
  DATA_DEV=$DEV2
else
  if [ "$DEV1_SIZE" -gt "$DEV2_SIZE" ]; then
    DATA_DEV=$DEV1
    DOCKER_DEV=$DEV2
  else
    DATA_DEV=$DEV2
    DOCKER_DEV=$DEV1
  fi
fi

# log devices
echo "DATA_DEV: $DATA_DEV"
echo "DOCKER_DEV: $DOCKER_DEV"

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

  # format XFS
  mkfs.xfs -f $DATA_DEV

  # mount as ${DATA_DIR}
  mkdir -p $DATA_DIR || true
  mount $DATA_DEV $DATA_DIR

  # create work and unpack index style
  mkdir -p ${DATA_DIR}/work || true
  tar xvfj $(eval echo "~${user}/verdi/src/beefed-autoindex-open_in_new_win.tbz2") -C ${DATA_DIR}/work || true

  # set permissions
  chown -R ${user}:${group} ${DATA_DIR} || true

  # create docker dir
  mkdir -p ${DATA_DIR}/var/lib/docker
  rm -rf /var/lib/docker || mv -f /var/lib/docker /var/lib/docker.orig
  ln -sf ${DATA_DIR}/var/lib/docker /var/lib/docker
fi

# Setup docker volume storage
if [[ -e "$DOCKER_DEV" ]]; then
  # clean out docker
  rm -rf /var/lib/docker/*

  # unmount block device if not already
  umount $DOCKER_DEV 2>/dev/null || true

  # remove volume group
  vgremove -ff docker || true

  # remove physical volume
  pvremove -ff $DOCKER_DEV || true

#  # determine 75% of volume size to be used for docker data
#  DATA_SIZE=`lsblk -b $DOCKER_DEV | grep disk | awk '{printf "%.0f\n", $4/1024^3*.75}'`
#
#  # create physical volume and volume group for docker
#  pvcreate -ff $DOCKER_DEV
#  vgcreate -ff docker $DOCKER_DEV
#
#  # create logical volumes
#  lvcreate --wipesignatures y -n thinpool docker -l 95%VG
#  lvcreate --wipesignatures y -n thinpoolmeta docker -l 1%VG
#
#  # convert logical volumes to a thin pool and storage location for metadata
#  lvconvert -y --zero n -c 512K --thinpool docker/thinpool --poolmetadata docker/thinpoolmeta
#
#  # configure autoextension of thin pools
#  echo "activation {" > /etc/lvm/profile/docker-thinpool.profile
#  echo "  thin_pool_autoextend_threshold=80" >> /etc/lvm/profile/docker-thinpool.profile
#  echo "  thin_pool_autoextend_percent=20" >> /etc/lvm/profile/docker-thinpool.profile
#  echo "}" >> /etc/lvm/profile/docker-thinpool.profile
#
#  # apply LVM profile
#  lvchange --metadataprofile docker-thinpool docker/thinpool
#
#  # enable monitoring for logical volumes
#  lvs -o+seg_monitor

  # configure docker daemon for devicemapper
  cat << EOF > /etc/docker/daemon.json
{
  "storage-driver": "devicemapper",
  "storage-opts": [
    "dm.directlvm_device=${DOCKER_DEV}",
    "dm.thinp_percent=95",
    "dm.thinp_metapercent=1",
    "dm.thinp_autoextend_threshold=80",
    "dm.thinp_autoextend_percent=20",
    "dm.directlvm_device_force=true",
    "dm.use_deferred_removal=true",
    "dm.use_deferred_deletion=true",
    "dm.fs=xfs",
    "dm.basesize=100G"
  ]
}
EOF

fi

$reset_docker
$start_docker
