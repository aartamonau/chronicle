#!/bin/bash

echo "Running vm-setup script"

apt-get update
apt-get install -y gcc g++ erlang-base rebar3
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/allow_passwords.conf
systemctl reload sshd.service
echo vagrant:vagrant | chpasswd
sed -i '1i PATH="$PATH:/usr/sbin"; export PATH' /home/vagrant/.bashrc

echo "AAAAAAAAAAAAAAAAAAAA" > /home/vagrant/.erlang.cookie
chown vagrant:vagrant /home/vagrant/.erlang.cookie
chmod 400 /home/vagrant/.erlang.cookie

# Force git to use https over ssh
sudo -u vagrant git config --global url."https://github.com/".insteadOf git@github.com:
