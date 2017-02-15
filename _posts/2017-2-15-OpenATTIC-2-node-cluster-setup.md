---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'OpenATTIC 2-node cluster setup'
categories: 
  - Storage
tags: [high-availability, cluster, openattic]
date: 2017-2-15
series: "OpenATTIC 2-node cluster setup"
gallery:
  - url: oattic-1.2-cluster-setup.png
    image_path: oattic-1.2-cluster-setup_600x300.png
    alt: "placeholder image 1"
    title: "OpenATTIC cluster nodes"
  - url: oattic-1.2-cluster-drbd-mirror-volume.png
    image_path: oattic-1.2-cluster-drbd-mirror-volume_600x300.png
    alt: "placeholder image 2"
    title: "OpenATTIC DRBD mirror"
---

[OpenATTIC](http://openattic.org) is an opensource converged storage that I think has a great potential to become a unified SDS for virtualization platforms. It offers features like CIFS, NFS, iSCSI and CEPH storage backends, mirrored volumes via DRBD and support for LVM, ZFS, XFS and Btrfs just to mention some.

Test setup is on two identical Ubuntu-14-04 VM's, `oattic01` and `oattic02`.

```
root@oattic01:~# lsb_release -a
No LSB modules are available.
Distributor ID:	Ubuntu
Description:	Ubuntu 14.04.5 LTS
Release:	14.04
Codename:	trusty
```

Since I want to run a cluster of two nodes I need to configure Highly Available PostgreSQL DB first for OpenATTIC (oA for short) to store its configuration into. This is going to be the first part of the setup and the second part will be the installation and setup of the oA it self.

{% include series.html %}  

Packages for `version 1.2.1` downloaded from OpenATTIC official site and ready for install, I want to test most of the modules available hence have downloaded all/most of the deb packages available:

```
root@oattic01:~# ls -1 openattic* | sort
openattic_1.2.1-1_all.deb
openattic-base_1.2.1-1_all.deb
openattic-module-apt_1.2.1-1_all.deb
openattic-module-btrfs_1.2.1-1_all.deb
openattic-module-cron_1.2.1-1_all.deb
openattic-module-drbd_1.2.1-1_all.deb
openattic-module-ftp_1.2.1-1_all.deb
openattic-module-http_1.2.1-1_all.deb
openattic-module-ipmi_1.2.1-1_all.deb
openattic-module-lio_1.2.1-1_all.deb
openattic-module-lvm_1.2.1-1_all.deb
openattic-module-mailaliases_1.2.1-1_all.deb
openattic-module-mdraid_1.2.1-1_all.deb
openattic-module-nagios_1.2.1-1_all.deb
openattic-module-nfs_1.2.1-1_all.deb
openattic-module-samba_1.2.1-1_all.deb
openattic-module-zfs_1.2.1-1_all.deb
openattic-pgsql_1.2.1-1_all.deb
```

To find some package dependencies before we install we can run:

```
root@oattic02:~# for i in openattic-module-*.deb; do dpkg -I $i | grep -i depends 2> /dev/null; done
 Depends: python-apt, openattic-base
 Depends: openattic-base, btrfs-tools
 Depends: cron, openattic-base
 Depends: openattic-module-lvm, drbd8-utils
 Depends: openattic-base, openattic-module-samba, proftpd-basic (>= 1.3.3), proftpd-mod-winbind
 Depends: openattic-base, apache2
 Depends: ipmitool, openattic-base
 Depends: openattic-base, python-rtslib (>> 2.1-2), lio-utils
 Depends: openattic-base, lvm2, parted, openattic-module-cron, file, udisks
 Depends: openattic-base, mail-transport-agent
 Depends: openattic-base, mdadm
 Depends: python (>= 2.6), python-imaging, python-numpy, openattic-base, bc, adduser, nagios3-core, nagios-plugins-standard, nagios-plugins-basic, pnp4nagios-bin, rrdtool
 Depends: openattic-base, nfs-kernel-server
 Depends: openattic-base, samba, samba-common-bin, winbind, libnss-winbind, krb5-user | heimdal-clients, libpam-krb5
 Depends: openattic-base, debian-zfs | ubuntu-zfs
  checksums. It depends on zfsonlinux, the native Linux port of ZFS.
```

So first installed the following packages:

```
root@oattic01:~# aptitude install nagios3-core nfs-kernel-server postfix php-xml-rpc2 \
ntp vlan ifenslave-2.6 lvm2 udisks python-dbus python-gobject python-m2crypto python-rtslib \
python-numpy python-netifaces python-netaddr btrfs-tools ipmitool ubuntu-zfs pnp4nagios-bin \
python-pyudev libapache2-mod-wsgi drbd8-utils lio-utils mdadm samba winbind libnss-winbind \
dbconfig-common postgresql
```

after which I installed the OpenATTIC packages:

```
root@oattic01:~# dpkg -i openattic*.deb
Selecting previously unselected package openattic.
(Reading database ... 146951 files and directories currently installed.)
Preparing to unpack openattic_1.2.1-1_all.deb ...
Unpacking openattic (1.2.1-1) ...
Selecting previously unselected package openattic-base.
Preparing to unpack openattic-base_1.2.1-1_all.deb ...
openattic:x:105:112::/var/lib/openattic:/bin/bash
The user `www-data' is already a member of `openattic'.
The user `openattic' is already a member of `www-data'.
Unpacking openattic-base (1.2.1-1) ...
Selecting previously unselected package openattic-module-apt.
Preparing to unpack openattic-module-apt_1.2.1-1_all.deb ...
Unpacking openattic-module-apt (1.2.1-1) ...
Selecting previously unselected package openattic-module-btrfs.
Preparing to unpack openattic-module-btrfs_1.2.1-1_all.deb ...
Unpacking openattic-module-btrfs (1.2.1-1) ...
Selecting previously unselected package openattic-module-cron.
Preparing to unpack openattic-module-cron_1.2.1-1_all.deb ...
Unpacking openattic-module-cron (1.2.1-1) ...
Selecting previously unselected package openattic-module-drbd.
Preparing to unpack openattic-module-drbd_1.2.1-1_all.deb ...
Unpacking openattic-module-drbd (1.2.1-1) ...
Selecting previously unselected package openattic-module-ftp.
Preparing to unpack openattic-module-ftp_1.2.1-1_all.deb ...
Unpacking openattic-module-ftp (1.2.1-1) ...
Selecting previously unselected package openattic-module-http.
Preparing to unpack openattic-module-http_1.2.1-1_all.deb ...
Unpacking openattic-module-http (1.2.1-1) ...
Selecting previously unselected package openattic-module-ipmi.
Preparing to unpack openattic-module-ipmi_1.2.1-1_all.deb ...
Unpacking openattic-module-ipmi (1.2.1-1) ...
Selecting previously unselected package openattic-module-lio.
Preparing to unpack openattic-module-lio_1.2.1-1_all.deb ...
Unpacking openattic-module-lio (1.2.1-1) ...
Selecting previously unselected package openattic-module-lvm.
Preparing to unpack openattic-module-lvm_1.2.1-1_all.deb ...
Unpacking openattic-module-lvm (1.2.1-1) ...
Selecting previously unselected package openattic-module-mailaliases.
Preparing to unpack openattic-module-mailaliases_1.2.1-1_all.deb ...
Unpacking openattic-module-mailaliases (1.2.1-1) ...
Selecting previously unselected package openattic-module-mdraid.
Preparing to unpack openattic-module-mdraid_1.2.1-1_all.deb ...
Unpacking openattic-module-mdraid (1.2.1-1) ...
Selecting previously unselected package openattic-module-nagios.
Preparing to unpack openattic-module-nagios_1.2.1-1_all.deb ...
Unpacking openattic-module-nagios (1.2.1-1) ...
Selecting previously unselected package openattic-module-nfs.
Preparing to unpack openattic-module-nfs_1.2.1-1_all.deb ...
Unpacking openattic-module-nfs (1.2.1-1) ...
Selecting previously unselected package openattic-module-samba.
Preparing to unpack openattic-module-samba_1.2.1-1_all.deb ...
Unpacking openattic-module-samba (1.2.1-1) ...
Selecting previously unselected package openattic-module-zfs.
Preparing to unpack openattic-module-zfs_1.2.1-1_all.deb ...
Unpacking openattic-module-zfs (1.2.1-1) ...
Selecting previously unselected package openattic-pgsql.
Preparing to unpack openattic-pgsql_1.2.1-1_all.deb ...
Unpacking openattic-pgsql (1.2.1-1) ...
Setting up openattic-pgsql (1.2.1-1) ...
dbconfig-common: writing config to /etc/dbconfig-common/openattic-pgsql.conf
creating postgres user openatticpgsql:  already exists.
resetting password:  success.
creating database openatticpgsql: already exists.
dbconfig-common: flushing administrative password
Setting up openattic-base (1.2.1-1) ...
 * Reloading web server apache2 * 
Processing triggers for ureadahead (0.100.0-16) ...
Setting up openattic-module-cron (1.2.1-1) ...
Setting up openattic-module-http (1.2.1-1) ...
 * Reloading web server apache2 * 
Setting up openattic-module-ipmi (1.2.1-1) ...
Setting up openattic-module-lio (1.2.1-1) ...
Setting up openattic-module-lvm (1.2.1-1) ...
Setting up openattic-module-mailaliases (1.2.1-1) ...
Setting up openattic-module-mdraid (1.2.1-1) ...
Setting up openattic-module-nagios (1.2.1-1) ...
Setting up openattic-module-nfs (1.2.1-1) ...
 * Exporting directories for NFS kernel daemon...                                                                                                                                                            [ OK ] 
 * Starting NFS kernel daemon                                                                                                                                                                                [ OK ] 
Setting up openattic-module-samba (1.2.1-1) ...
Setting up openattic-module-zfs (1.2.1-1) ...
Setting up openattic-module-apt (1.2.1-1) ...
Setting up openattic-module-btrfs (1.2.1-1) ...
Setting up openattic-module-drbd (1.2.1-1) ...
Setting up openattic-module-ftp (1.2.1-1) ...
Setting up openattic (1.2.1-1) ...
Processing triggers for man-db (2.6.7.1-1ubuntu1) ...
```

After installing all needed software on both servers we create the `/etc/openattic/database.ini` file as shown below:

``` 
[default]
engine   = django.db.backends.postgresql_psycopg2
name     = openatticpgsql
user     = openatticpgsql
password = password
host     = 10.20.1.200 
port     =
```

The important bit is setting the host parameter to the VIP of the PostgreSQL cluster `10.20.1.200` as per installation in Part 1. Then we run the `oaconfig install` utility to finish the setup (the output is from oattic02 node install):

```
root@oattic02:~# oaconfig install
systemd is running (pid 21865).
 * Stopping openATTIC systemd                             [ OK ] 
 * Starting openATTIC systemd                             [ OK ] 
 * Stopping openATTIC rpcd  No /usr/bin/python found running; none killed.           [ OK ]
 * Starting openATTIC rpcd                                [ OK ] 
 * Reloading web server apache2 
 * 
Creating tables ...
Installing custom SQL ...
Installing indexes ...
Installed 65 object(s) from 2 fixture(s)
 * Stopping openATTIC systemd                              [ OK ] 
 * Starting openATTIC systemd                              [ OK ] 
 * Stopping openATTIC rpcd                                 [ OK ] 
 * Starting openATTIC rpcd                                 [ OK ] 
 * Reloading web server apache2 
 * 
We have an admin already, not creating default user.
ProFTPD is started in standalone mode, currently running.
md5sum: /var/www/index.html: No such file or directory
Adding lo
Adding  {'peer': '127.0.0.1', 'netmask': '255.0.0.0', 'addr': '127.0.0.1'}
Adding  {'netmask': 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff', 'addr': '::1'}
Adding eth1
Adding  {'broadcast': '10.10.1.255', 'netmask': '255.255.255.0', 'addr': '10.10.1.17'}
Adding eth2
Adding  {'broadcast': '10.20.1.255', 'netmask': '255.255.255.0', 'addr': '10.20.1.18'}
Adding  {'broadcast': '10.20.1.255', 'netmask': '255.255.255.0', 'addr': '10.20.1.200'}
Adding eth0
Adding  {'broadcast': '192.168.0.255', 'netmask': '255.255.255.0', 'addr': '192.168.0.135'}
Adding  {'broadcast': '192.168.0.255', 'netmask': '255.255.255.0', 'addr': '192.168.0.241'}
Adding  {'broadcast': '192.168.0.255', 'netmask': '255.255.255.0', 'addr': '192.168.0.242'}
Adding Volume Group vg1
Adding Service 'Current Load'
Adding Service 'Current Users'
Adding Service 'Disk Space'
Adding Service 'HTTP'
Adding Service 'SSH'
Adding Service 'Total Processes'
Adding Service 'openATTIC RPCd'
Adding Service 'openATTIC Systemd'
Completed successfully.
```

Then copy the oA Apache config files to the proper location for Apache 2.x version:

```
root@oattic01:~# cp /etc/apache2/conf.d/openattic /etc/apache2/conf-available/openattic.conf
root@oattic01:~# cp /etc/apache2/conf.d/openattic-volumes /etc/apache2/conf-available/openattic-volumes.conf
root@oattic01:~# cp /etc/apache2/conf.d/pnp4nagios.conf /etc/apache2/conf-available/
```

then enable them:

```
root@oattic01:~# a2enconf openattic openattic-volumes pnp4nagios
Enabling conf openattic.
Enabling conf openattic-volumes.
Enabling conf pnp4nagios.
To activate the new configuration, you need to run:
  service apache2 reload
```

and reload Apache:

```
root@oattic01:~# service apache2 reload
 * Reloading web server apache2 * 
```

after we finish the procedure on both nodes we are able to access the web UI at `http://oattic01` and `http://oattic02` (read about issues and workarounds below though). 

Next (execute on one server only) set password for the `openattic` user, I set it to openattic:

```
root@oattic01:~# oaconfig changepassword
Changing password for user 'openattic'
Password: 
Password (again): 
Password changed successfully for user 'openattic'
root@oattic01:~# 
```

The list of packages installed:

```
root@oattic02:~# dpkg -l | grep openatt
ii  openattic                            1.2.1-1                              all          Comprehensive storage management system
ii  openattic-base                       1.2.1-1                              all          Basic requirements for openATTIC
ii  openattic-module-apt                 1.2.1-1                              all          APT module for openATTIC
ii  openattic-module-btrfs               1.2.1-1                              all          BTRFS module for openATTIC
ii  openattic-module-cron                1.2.1-1                              all          Cron module for openATTIC
ii  openattic-module-drbd                1.2.1-1                              all          DRBD module for openATTIC
ii  openattic-module-ftp                 1.2.1-1                              all          FTP module for openATTIC
ii  openattic-module-http                1.2.1-1                              all          HTTP module for openATTIC
ii  openattic-module-ipmi                1.2.1-1                              all          IPMI module for openATTIC
ii  openattic-module-lio                 1.2.1-1                              all          LIO module for openATTIC
ii  openattic-module-lvm                 1.2.1-1                              all          LVM module for openATTIC
ii  openattic-module-mailaliases         1.2.1-1                              all          MailAliases module for openATTIC
ii  openattic-module-mdraid              1.2.1-1                              all          MDRAID module for openATTIC
ii  openattic-module-nagios              1.2.1-1                              all          Nagios module for openATTIC
ii  openattic-module-nfs                 1.2.1-1                              all          NFS module for openATTIC
ii  openattic-module-samba               1.2.1-1                              all          Samba module for openATTIC
ii  openattic-module-zfs                 1.2.1-1                              all          ZFS module for openATTIC
ii  openattic-pgsql                      1.2.1-1                              all          PGSQL database for openATTIC
```

In case we have changed something or installed a new module after the initial install we can always re-run `oaconfig install` to bring the system up-to-date.

{% include gallery caption="OpenATTIC-1.2.1" %}

# Issues and workarounds 

Initially the oaconfig command failed due to the `openattic_rpcd` daemon not being able to start because of the log file `/var/log/openattic_rpcd` permissions, the installer created this file with `root` ownership for some reason. Changing the ownership:

```
root@[ALL]:~# chown openattic\: /var/log/openattic_rpcd
```

solved the problem and the next run of `oaconfig install` was successful.

At the end I got `Bad Request (400)` error when tried to access the web UI. Adding `ALLOWED_HOSTS` parameter to `/etc/openattic/settings.py` solves the problem for Django-1.6.11 and Python-2.7. In my case I just added:

```
ALLOWED_HOSTS = [ '*' ]
```

to `/etc/openattic/settings.py` and restarted Apache.