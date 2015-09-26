#!/bin/bash

usage(){
    echo "bootstrap.sh [options]"
    echo "  -b          Set up a obsf4 Tor bridge"
    echo "  -r          Set up a (non-exit) Tor relay"
    echo "  -x          Set up a Tor exit relay (default is a reduced exit)"
    exit -1
}

# pretty colors
GREEN='\e[0;32m'
RED='\e[0;31'
PURPLE='\e[0;35'
NC='\e[0m'

# Process options
unset TYPE
while getopts "brx" option; do
  case $option in
    b ) [ -n "$TYPE" ] && usage ; TYPE="bridge" ;;
    r ) [ -n "$TYPE" ] && usage ; TYPE="relay" ;;
    x ) [ -n "$TYPE" ] && usage ; TYPE="exit" ;;
    * ) usage ;;
    esac
done

# check for root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}" 1>&2
    exit 1
fi

PWD="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# update software
echo -e "${PURPLE}== Updating software"
apt-get update
apt-get dist-upgrade -y

# apt-transport-https allows https debian mirrors. it's more fun that way.
# https://guardianproject.info/2014/10/16/reducing-metadata-leakage-from-software-updates/
# granted it doesn't fix *all* metadata problems
# see https://labs.riseup.net/code/issues/8143 for more on this discussion
apt-get install -y lsb-release apt-transport-https

# add official Tor repository w/ https
if ! grep -q "https://deb.torproject.org/torproject.org" /etc/apt/sources.list; then
    echo "== Adding the official Tor repository"
    echo "deb https://deb.torproject.org/torproject.org `lsb_release -cs` main" >> /etc/apt/sources.list
    gpg --keyserver keys.gnupg.net --recv A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
    gpg --export A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89 | apt-key add -
    apt-get update
fi

# install tor and related packages
echo "== Installing Tor and related packages"
if [[ "$TYPE" == "relay" ]] ||  [[ "$TYPE" == "exit" ]] ; then
    apt-get install -y deb.torproject.org-keyring tor tor-arm tor-geoipdb
elif [ "$TYPE" == "bridge" ] ; then
    apt-get install -y deb.torproject.org-keyring tor tor-arm tor-geoipdb obfsproxy golang libcap2-bin
    go get git.torproject.org/pluggable-transports/obfs4.git/obfs4proxy
fi
service tor stop

# configure tor
if [ "$TYPE" == "relay" ] ; then
    cp $PWD/etc/tor/relaytorrc /etc/tor/torrc
elif [ "$TYPE" == "bridge" ] ; then
    cp $PWD/etc/tor/bridgetorrc /etc/tor/torrc
elif [ "$TYPE" == "exit" ] ; then
    cp $PWD/etc/tor/exittorrc /etc/tor/torrc
fi

# configure firewall rules
echo "== Configuring firewall rules"
apt-get install -y debconf-utils
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
apt-get install -y iptables iptables-persistent
if [ "$TYPE" == "relay" ] ; then
    cp $PWD/etc/iptables/relayrules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/relayrules.v6 /etc/iptables/rules.v6
elif [ "$TYPE" == "bridge" ] ; then
    cp $PWD/etc/iptables/bridgerules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/bridgerules.v6 /etc/iptables/rules.v6
elif [ "$TYPE" == "exit" ] ; then
    cp $PWD/etc/iptables/exitrules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/exitrules.v6 /etc/iptables/rules.v6
fi
chmod 600 /etc/iptables/rules.v4
chmod 600 /etc/iptables/rules.v6
iptables-restore < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6

apt-get install -y fail2ban

# configure automatic updates
echo "== Configuring unattended upgrades"
apt-get install -y unattended-upgrades apt-listchanges
cp $PWD/etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
service unattended-upgrades restart

# install apparmor
apt-get install -y apparmor apparmor-profiles apparmor-utils
sed -i.bak 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 apparmor=1 security=apparmor"/' /etc/default/grub
update-grub

# install tlsdate
apt-get install -y tlsdate

# configure sshd
ORIG_USER=$(logname)
if [ -n "$ORIG_USER" ]; then
	echo -e "== Configuring sshd ${NC}"
	# only allow the current user to SSH in
	echo "AllowUsers $ORIG_USER" >> /etc/ssh/sshd_config
	echo "  - SSH login restricted to user: $ORIG_USER"
	if grep -q "Accepted publickey for $ORIG_USER" /var/log/auth.log; then
		# user has logged in with SSH keys so we can disable password authentication
		sed -i '/^#\?PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
		echo "  - SSH password authentication disabled"
		if [ $ORIG_USER == "root" ]; then
			# user logged in as root directly (rather than using su/sudo) so make sure root login is enabled
			sed -i '/^#\?PermitRootLogin/c\PermitRootLogin yes' /etc/ssh/sshd_config
		fi
	else
		# user logged in with a password rather than keys
		echo -e "${RED}  - You do not appear to be using SSH key authentication.  You should set this up manually now.${NC}"
	fi
	service ssh reload
else
	echo -e "${RED}== Could not configure sshd automatically.  You will need to do this manually.${NC}"
fi

# final instructions
echo ""
echo -e "${GREEN}== Try SSHing into this server again in a new window, to confirm the firewall isn't broken"
echo ""
echo "== Edit /etc/tor/torrc"
echo "  - Set Address, Nickname, Contact Info, and MyFamily for your Tor relay"
echo "  - Optional: include a Bitcoin address in the 'ContactInfo' line"
echo "  - This will enable you to receive donations from OnionTip.com"
echo ""
echo "== Register your new Tor relay at Tor Weather (https://weather.torproject.org/)"
echo "   to get automatic emails about its status"
echo ""
echo "== Consider having /etc/apt/sources.list update over HTTPS and/or HTTPS+Tor"
echo "   see https://guardianproject.info/2014/10/16/reducing-metadata-leakage-from-software-updates/"
echo "   for more details"
echo ""
echo -e "== REBOOT THIS SERVER${NC}"
