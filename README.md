# docker-ephemeral-lvm
Script for setting up the devicemapper docker storage backend on an EC2 ephemeral disk

Installation
------------
1. sudo mv docker-ephemeral-lvm.* /etc/systemd/system/
2. sudo systemctl enable docker-ephemeral-lvm
3. sudo reboot
