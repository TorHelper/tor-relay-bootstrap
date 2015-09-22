tor-bootstrap
===================

This is a script to bootstrap a Debian server to be a set-and-forget Tor relay, bridge, or exit. This script is meant for a Debian Jessie host.

Pull requests are welcome.

tor-relay-bootstrap does this:

* Upgrades all the software on the system
* Adds the deb.torproject.org repository to apt, so Tor updates will come directly from the Tor Project
* Installs and configures Tor to become a relay, bridge, or exit based off of the corresponding flag that is passed to the program. This still requires you to manually edit torrc to set Nickname, ContactInfo, etc. for this relay.
* Configures sane default firewall rules
* Configures automatic updates
* Installs tlsdate to ensure time is synced
* Installs monit and activate config to auto-restart all services
* Helps harden the ssh server
* Gives instructions on what the sysadmin needs to manually do at the end

To use it, set up a Debian server, SSH into it, switch to the root user, and:

```sh
git clone https://github.com/micahflee/tor-relay-bootstrap.git
cd tor-relay-bootstrap
./bootstrap.sh
```
