#!/bin/sh -e
# This script will DESTROY /dev/xvdc and remount it for Docker volume storage.
# It is intended for EC2 instances with 2 ephemeral SSD instance stores like 
# the c3.xlarge instance type.

systemctl stop docker || true

# Setup Instance Store 1 for Docker volume storage
DEV="/dev/xvdc"
if [[ -e "$DEV" ]]; then
  # clean out docker
  rm -rf /var/lib/docker

  # unmount block device if not already
  umount $DEV 2>/dev/null || true

  # remove volume group
  vgremove -ff vg-docker || true

  # remove physical volume
  pvremove -ff $DEV || true

  # determine 75% of volume size to be used for docker data
  DATA_SIZE=`lsblk -b $DEV | grep disk | awk '{printf "%.0f\n", $4/1024^3*.75}'`

  # create physical volume and volume group for docker
  pvcreate -ff $DEV
  vgcreate -ff  vg-docker $DEV

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
