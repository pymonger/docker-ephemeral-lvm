# docker-ephemeral-lvm
Script for setting up the devicemapper docker storage backend on an EC2 ephemeral disk

Installation
------------
1. sudo systemctl stop docker
2. sudo mv docker-ephemeral-lvm.* /etc/systemd/system/
3. sudo systemctl enable docker-ephemeral-lvm
4. sudo systemctl start docker-ephemeral-lvm
