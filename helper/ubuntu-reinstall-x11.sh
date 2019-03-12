# https://www.computersnyou.com/4945/re-install-xorg-xserver-completely-ubuntu/

# remove
apt-get purge xorg "xserver-*"
apt-get purge lightdm plymouth
rm -rf /etc/X11/xorg

# install
apt-get install xauth xorg openbox lightdm plymouth
apt-get install ubuntu-desktop

