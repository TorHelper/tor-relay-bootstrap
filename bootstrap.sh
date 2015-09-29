#!/bin/sh

set -e # terminate script if any step fails
set -u # abort if any variables are unset

usage(){
    echo "bootstrap.sh [options]"
    echo "  -b          Set up a obsf4 Tor bridge"
    echo "  -r          Set up a (non-exit) Tor relay"
    echo "  -x          Set up a Tor exit relay (default is a reduced exit)"
    exit 255
}

# pretty colors
echo_green() { printf "\033[0;32m$1\033[0;39;49m\n"; }
echo_red() { printf "\033[0;31m$1\033[0;39;49m\n"; }

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
if [ $(id -u) -ne 0 ]; then
    echo_red "This script must be run as root" 1>&2
    exit 1
fi

PWD="$(dirname "$0")"

# packages that we always install
TORPKGSCOMMON="deb.torproject.org-keyring tor tor-arm tor-geoipdb"

# update software
echo_green "== Updating software"
apt-get update
apt-get dist-upgrade -y

# apt-transport-https allows https debian mirrors. it's more fun that way.
# https://guardianproject.info/2014/10/16/reducing-metadata-leakage-from-software-updates/
# granted it doesn't fix *all* metadata problems
# see https://labs.riseup.net/code/issues/8143 for more on this discussion
apt-get install -y lsb-release apt-transport-https

# add official Tor repository w/ https
if ! fgrep -rq "https://deb.torproject.org/torproject.org" /etc/apt/sources.list*; then
    echo_green "== Adding the official Tor repository"
    echo "deb https://deb.torproject.org/torproject.org `lsb_release -cs` main" >> /etc/apt/sources.list
    apt-key adv --keyserver keys.gnupg.net --recv A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89
    apt-get update
fi

# install tor and related packages
echo_green "== Installing Tor and related packages"
if [ "$TYPE" = "relay" ] ||  [ "$TYPE" = "exit" ] ; then
    apt-get install -y $TORPKGSCOMMON
elif [ "$TYPE" = "bridge" ] ; then
    apt-get install -y $TORPKGSCOMMON obfsproxy golang libcap2-bin
    go get git.torproject.org/pluggable-transports/obfs4.git/obfs4proxy
fi
service tor stop

# configure tor
if [ "$TYPE" = "relay" ] ; then
    cp $PWD/etc/tor/relaytorrc /etc/tor/torrc
elif [ "$TYPE" = "bridge" ] ; then
    cp $PWD/etc/tor/bridgetorrc /etc/tor/torrc
elif [ "$TYPE" = "exit" ] ; then
    cp $PWD/etc/tor/exittorrc /etc/tor/torrc
fi

# configure firewall rules
echo_green "== Configuring firewall rules"
apt-get install -y debconf-utils
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
apt-get install -y iptables iptables-persistent
if [ "$TYPE" = "relay" ] ; then
    cp $PWD/etc/iptables/relayrules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/relayrules.v6 /etc/iptables/rules.v6
elif [ "$TYPE" = "bridge" ] ; then
    cp $PWD/etc/iptables/bridgerules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/bridgerules.v6 /etc/iptables/rules.v6
elif [ "$TYPE" = "exit" ] ; then
    cp $PWD/etc/iptables/exitrules.v4 /etc/iptables/rules.v4
    cp $PWD/etc/iptables/exitrules.v6 /etc/iptables/rules.v6
fi
chmod 600 /etc/iptables/rules.v4
chmod 600 /etc/iptables/rules.v6
iptables-restore < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6

apt-get install -y fail2ban

# configure automatic updates
echo_green "== Configuring unattended upgrades"
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
	echo_green "== Configuring sshd"
	# only allow the current user to SSH in
	echo "AllowUsers $ORIG_USER" >> /etc/ssh/sshd_config
	echo "  - SSH login restricted to user: $ORIG_USER"
	if grep -q "Accepted publickey for $ORIG_USER" /var/log/auth.log; then
		# user has logged in with SSH keys so we can disable password authentication
		sed -i '/^#\?PasswordAuthentication/c\PasswordAuthentication no' /etc/ssh/sshd_config
		echo "  - SSH password authentication disabled"
		if [ $ORIG_USER = "root" ]; then
			# user logged in as root directly (rather than using su/sudo) so make sure root login is enabled
			sed -i '/^#\?PermitRootLogin/c\PermitRootLogin yes' /etc/ssh/sshd_config
		fi
	else
		# user logged in with a password rather than keys
		echo_red "  - You do not appear to be using SSH key authentication."
		echo_red "    You should set this up manually now."
	fi
	service ssh reload
else
	echo_red "== Could not configure sshd automatically.  You will need to do this manually."
fi

# final instructions
echo_green "
== Try SSHing into this server again in a new window, to confirm the firewall
   isn't broken

== Edit /etc/tor/torrc
  - Set Address, Nickname, Contact Info, and MyFamily for your Tor relay
  - Optional: include a Bitcoin address in the 'ContactInfo' line
  - This will enable you to receive donations from OnionTip.com

== Register your new Tor relay at Tor Weather (https://weather.torproject.org/)
   to get automatic emails about its status

== Consider having /etc/apt/sources.list update over HTTPS and/or HTTPS+Tor
   see https://guardianproject.info/2014/10/16/reducing-metadata-leakage-from-software-updates/
   for more details

== REBOOT THIS SERVER
"
