---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Windows Active Directory with SAMBA4'
categories: 
  - Server
tags: ['samba', 'windows', 'AD/DC']
date: 2013-8-6
---
{% include toc %}
Setting up an Active Directory server for company domain is a must in these days. It provides centralized management of user rights and permissions and secure access to shared resources. It is very convenient for exporting users home directories thus avoiding the need of backups. It also provides SSO (Single Sign On) for various services like Apache, SSH, Nslcd etc. using Kerberos MIT tickets. The newly released Samba4 makes this set up free of the usual Microsoft AC charges and licences.

# Preparation

We'll be using CentOS6.4 x86_64 for OS for our Active Directory server. It will be running as a VM (smb4dc) inside our office PVE virtualization server.

## Setup network interface and FQDN on the VM instance

After we launch our VM, we connect via VNC console and create the following network interface file:

```
[root@smb4dc]# vi /etc/sysconfig/network-scripts/ifcfg-eth0
DEVICE=eth0
HWADDR=CE:A2:5B:FD:FE:AB
TYPE=Ethernet
UUID=afda1fa7-1e90-4821-b9e4-d5f08460663d
ONBOOT=yes
NM_CONTROLLED=yes
BOOTPROTO=none
IPADDR=192.168.0.107
GATEWAY=192.168.0.1
NETMASK=255.255.255.0
DNS1=192.168.0.107
DEFROUTE=yes
IPV6INIT=no
```

to make the VM part of our office network. We set up the host name too:

```
[root@smb4dc]# vi /etc/sysconfig/network
NETWORKING=yes
HOSTNAME=smb4dc.encompass.com
```

to be part of our internal/private office domain `encompass.com`.

## Install needed packages, set user and switch off SElinux

```
[root@smb4dc]# yum install glibc glibc-devel gcc python* libacl-devel krb5-workstation krb5-libs pam_krb5 gnutls-devel openssl-devel libacl-devel git-core
 
[root@smb4dc]# useradd -c "Igor Cicimov" -m -s /bin/bash -G wheel igorc
[root@smb4dc]# passwd igorc
 
[root@smb4dc]# vi /etc/sysconfig/selinux
[root@smb4dc]# setenforce 0
```

## Prepare the file system

We need to set some extended user attributes on the file system for best SAMBA AD DC support. Recommended file systems are ext3, ext4 and xfs as ones with the needed features available. We use ext4 on our server. To enable the additional features we change:

```
/dev/mapper/VolGroup-lv_root /     ext4    defaults        1 1
```

to

```
/dev/mapper/VolGroup-lv_root /     ext4    user_xattr,acl,barrier=1        1 1
```

in `/etc/fstab.conf` file. Then we remount the file system:

```
[root@smb4dc]# mount -a -o remount,rw /
```

Without `barrier=1` the TDB database used by SAMBA can't be guaranteed to be consistent in case of system crash. The `xattr` and `acl` is needed for the windows share permissions set up and making them available on the user side.

# Samba

We need to download, compile and install the latest SAMBA from its official web site:

```
[igorc@smb4dc ~]$ git clone git://git.samba.org/samba.git samba-master
[igorc@smb4dc ~]$ cd samba-master
[igorc@smb4dc samba-master]$ ./configure --enable-debug --enable-selftest
[igorc@smb4dc samba-master]$ make
[igorc@smb4dc samba-master]$ sudo make install
[igorc@smb4dc samba-master]$ sudo shutdown -r now
```

Then we provision our internal `encompass.com` domain:

```
[igorc@smb4dc samba-master]$ sudo /usr/local/samba/bin/samba-tool domain provision
Realm [ENCOMPASS.COM]:
 Domain [ENCOMPASS]:
 Server Role (dc, member, standalone) [dc]:
 DNS backend (SAMBA_INTERNAL, BIND9_FLATFILE, BIND9_DLZ, NONE) [SAMBA_INTERNAL]:
 DNS forwarder IP address (write 'none' to disable forwarding) [192.168.0.1]: 8.8.8.8
Administrator password:
Retype password:
Looking up IPv4 addresses
Looking up IPv6 addresses
No IPv6 address will be assigned
Setting up share.ldb
Setting up secrets.ldb
Setting up the registry
Setting up the privileges database
Setting up idmap db
Setting up SAM db
Setting up sam.ldb partitions and settings
Setting up sam.ldb rootDSE
Pre-loading the Samba 4 and AD schema
Adding DomainDN: DC=encompass,DC=com
Adding configuration container
Setting up sam.ldb schema
Setting up sam.ldb configuration data
Setting up display specifiers
Modifying display specifiers
Adding users container
Modifying users container
Adding computers container
Modifying computers container
Setting up sam.ldb data
Setting up well known security principals
Setting up sam.ldb users and groups
Setting up self join
Adding DNS accounts
Creating CN=MicrosoftDNS,CN=System,DC=encompass,DC=com
Creating DomainDnsZones and ForestDnsZones partitions
Populating DomainDnsZones and ForestDnsZones partitions
Setting up sam.ldb rootDSE marking as synchronized
Fixing provision GUIDs
A Kerberos configuration suitable for Samba 4 has been generated at /usr/local/samba/private/krb5.conf
Once the above files are installed, your Samba4 server will be ready to use
Server Role:           active directory domain controller
Hostname:              smb4dc
NetBIOS Domain:        ENCOMPASS
DNS Domain:            encompass.com
DOMAIN SID:            S-1-5-21-4154966781-565189077-2949095343
```

I have chosen one of the public Google DNS servers (8.8.8.8) for DNS forwarder in the above configuration. When done the Samba config file will now look like this:

```
[root@smb4dc samba]# cat /usr/local/samba/etc/smb.conf
# Global parameters
[global]
        workgroup = ENCOMPASS
        realm = ENCOMPASS.COM
        netbios name = SMB4DC
        server role = active directory domain controller
        dns forwarder = 8.8.8.8
 
[netlogon]
        path = /usr/local/samba/var/locks/sysvol/encompass.com/scripts
        read only = No
 
[sysvol]
        path = /usr/local/samba/var/locks/sysvol
        read only = No
```

One good thing with this Samba release is that all those services Samba3 needed and which were running as external, ie DNS, OpenLDAP, winbind, Kerberos etc, are now built in into Samba4! It even provides Kerberos config file and setup. To check if DNS is working:

```
[root@smb4dc ~]# host -t SRV _ldap._tcp.encompass.com.
_ldap._tcp.encompass.com has SRV record 0 100 389 smb4dc.encompass.com.
 
[root@smb4dc ~]# host -t A smb4dc.encompass.com.
smb4dc.encompass.com has address 192.168.0.107
 
[root@smb4dc ~]# host -t SRV _kerberos._udp.encompass.com.
_kerberos._udp.encompass.com has SRV record 0 100 88 smb4dc.encompass.com.
```

We grab the Kerberos config provided by Samba4 and we copy it over under `/etc`:

```
[root@smb4dc ~]# mv /etc/krb5.conf /etc/krb5.conf.default
[root@smb4dc ~]# cp /usr/local/samba/private/krb5.conf /etc/krb5.conf
[root@smb4dc ~]# kinit administrator@ENCOMPASS.COM
Password for administrator@ENCOMPASS.COM:
Warning: Your password will expire in 41 days on Wed Sep 11 07:31:28 2013
[root@smb4dc ~]#
```

To check if its working:

```
[root@smb4dc ~]# klist
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: administrator@ENCOMPASS.COM
 
Valid starting     Expires            Service principal
07/31/13 07:47:31  07/31/13 17:47:31  krbtgt/ENCOMPASS.COM@ENCOMPASS.COM
    renew until 08/01/13 07:47:27
[root@smb4dc ~]#
```

## Start/stop

```
[root@smb4dc samba]# /usr/local/samba/sbin/samba
[root@smb4dc samba]# ps -ef | grep samba
root      5682     1  2 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5683  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5684  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5685  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5686  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5687  5682  6 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5688  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5689  5683  2 14:59 ?        00:00:00 /usr/local/samba/sbin/smbd -D --option=server role check:inhibit=yes --foreground
root      5690  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5691  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5692  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5693  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5694  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5695  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5696  5682  0 14:59 ?        00:00:00 /usr/local/samba/sbin/samba
root      5699  5689  0 14:59 ?        00:00:00 /usr/local/samba/sbin/smbd -D --option=server role check:inhibit=yes --foreground
root      5701  1475  0 15:00 pts/0    00:00:00 grep samba
 
[root@smb4dc samba]# kill -TERM 5682
```

# NTP

Time is very important in AD and all workstations that join the domain must be in sync with the DC. The allowed clock drift is just a couple of milliseconds.

For ntpd package compiled with SAMBA support we just do:

```
[root@smb4dc ~]# yum install ntp
[root@smb4dc ~]# chkconfig ntpd on
[root@smb4dc ~]# service ntpd start
Starting ntpd:                                             [  OK  ]

[root@smb4dc ~]# ntpstat
unsynchronised
  time server re-starting
   polling server every 64 s
 
[root@smb4dc ~]# ntpstat
synchronised to NTP server (27.54.95.12) at stratum 3
   time correct to within 37 ms
   polling server every 64 s

[root@smb4dc ~]# date
Wed Jul 31 18:12:50 EST 2013
```

But CentOS minimal install doesn't come with one. So we build from source to enable `signd` service for Samba support:

```
[igorc@smb4dc ~]$ wget http://www.eecis.udel.edu/~ntp/ntp_spool/ntp4/ntp-4.2/ntp-4.2.6p5.tar.gz
[igorc@smb4dc ~]$ tar -xzvf ntp-4.2.6p5.tar.gz
[igorc@smb4dc ~]$ cd ntp-4.2.6p5
[igorc@smb4dc ntp-4.2.6p5]$ ./configure --enable-ntp-signd
[igorc@smb4dc ntp-4.2.6p5]$ make
[igorc@smb4dc ntp-4.2.6p5]$ sudo make install
[igorc@smb4dc ntp-4.2.6p5]$ sudo vi /etc/ntpd.conf
 
server 127.127.1.0
fudge  127.127.1.0 stratum 10
server 0.pool.ntp.org  iburst prefer
server 1.pool.ntp.org  iburst prefer
driftfile /var/lib/ntp/ntp.drift
logfile /var/log/ntp
ntpsigndsocket /usr/local/samba/var/lib/ntp_signd/
restrict default kod nomodify notrap nopeer mssntp
restrict 127.0.0.1
restrict 0.pool.ntp.org mask 255.255.255.255 nomodify notrap nopeer noquery
restrict 1.pool.ntp.org mask 255.255.255.255 nomodify notrap nopeer noquery
```

SAMBA4 has Unix socket opened for communication with NTP in `/usr/local/samba/var/lib/ntp_signd/` hence the above configuration. We also set appropriate permissions on that directory so the ntp user has read access:

```
[igorc@smb4dc ntp-4.2.6p5]$ sudo chown root:ntp /usr/local/samba/var/lib/ntp_signd/
[igorc@smb4dc ntp-4.2.6p5]$ sudo chmod 0750 /usr/local/samba/var/lib/ntp_signd/
```

At the end we start the server:

```
[root@smb4dc samba]# /usr/local/bin/ntpd
```

and put the above command in `/etc/rc.d/rc.local` as well for auto start on boot up.

To check for peers and clock status:

```
[root@smb4dc samba]# ntpdc -s -l
client    dns1-ha.au.syrahost.com
client    LOCAL(0)
client    resolver02.as24220.net
     remote           local      st poll reach  delay   offset    disp
=======================================================================
*dns1-ha.au.syra 192.168.0.107    2   64   17 0.06996  0.003538 0.03880
 LOCAL(0)        127.0.0.1       10   64   14 0.00000  0.000000 1.98436
.resolver02.as24 192.168.0.107    2   64   17 0.03087  0.006614 0.04684
```

# Firewall

After we have set up the above services, we configure the firewall to have the following ports open:

```
53, TCP & UDP (DNS)
88, TCP & UDP (Kerberos authentication)
135, TCP (MS RPC)
137, UDP (NetBIOS name service)
138, UDP (NetBIOS datagram service)
139, TCP (NetBIOS session service)
389, TCP & UDP (LDAP)
445, TCP (MS-DS AD)
464, TCP & UDP (Kerberos change/set password)
1024, TCP (AD?)
```

The configuration:

```
[root@smb4dc ~]# vi /etc/sysconfig/iptables
# Firewall configuration written by system-config-firewall
# Manual customization of this file is not recommended.
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 22 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 53 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 53 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 88 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 88 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 135 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 137 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 138 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 139 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 389 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 389 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 445 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 464 -j ACCEPT
-A INPUT -m state --state NEW -m udp -p udp --dport 464 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 1024 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
```

And we restart the `iptables` service and set it to start up on boot time:

```
[root@smb4dc ~]# service iptables restart
[root@smb4dc ~]# chkconfig iptables on
```

# BIND as DNS back-end (optional)

This is in case we don't want to use the built in SAMBA4 DNS server. It's been given here just in case we already have DNS server running somewhere for our domain and we want to integrate it with Samba AD.

Compile latest BIND 9.9.3 atm with options for Samba DC (kerberos support etc.):

```
[igorc@smb4dc ~]$ wget http://www.isc.org/wp-content/plugins/email-before-download/download.php?dl=37303450643e068319c90adddd17506a
[igorc@smb4dc ~]$ tar -xzvf bind-9.9.3-P2.tar.gz
[igorc@smb4dc ~]$ cd bind-9.9.3-P2
[igorc@smb4dc bind-9.9.3-P2]$ ./configure --with-gssapi=/usr/include/gssapi --with-dlopen=yes
[igorc@smb4dc bind-9.9.3-P2]$ make
[igorc@smb4dc bind-9.9.3-P2]$ sudo make install
[igorc@smb4dc bind-9.9.3-P2]$ sudo cp ./bin/tests/system/common/rndc.key /etc/
```

Alternatively, the missing `rndc.key` can also be generated by running `rndc-confgen` command:

```
[root@smb4dc named]# rndc-confgen -a
wrote key file "/etc/rndc.key"
```

Set minimal named.conf file:

```
[root@smb4dc ~]# vi /etc/named.conf
 
# Global options
options {
       auth-nxdomain yes;
       directory "/var/named";
       forwarders { 8.8.8.8; 8.8.4.4; };
       allow-transfer { none; };
       notify no;
       empty-zones-enable no;
 
       allow-query {
               192.168.0.0/24;
       };
 
       allow-recursion {
               192.168.0.0/24;
       };
 
};
 
 
# Root servers (required zone for recursive queries)
zone "." {
       type hint;
       file "named.root";
};
 
 
# Required localhost forward-/reverse zones
 zone "localhost" {
       type master;
       file "zones/master/localhost.zone";
};
 
zone "0.0.127.in-addr.arpa" {
       type master;
       file "zones/master/0.0.127.zone";
};
```

Set BIND user account and directory:

```
[root@smb4dc ~]# groupadd -g 25 named
[root@smb4dc ~]# useradd -g named -u 25 -d /var/named -M -s /sbin/nologin named
[root@smb4dc ~]# mkdir /var/named
[root@smb4dc named]# mkdir -p /var/named/zones/master
```

Download the root name server list from InterNIC:

```
# wget -q -O /var/named/named.root http://www.internic.net/zones/named.root
# chown named:named /var/named/named.root
```

Create zone files:

```
[root@smb4dc named]# vi /var/named/zones/master/localhost.zone
 
$TTL 3D
 
$ORIGIN localhost.
 
@       1D      IN     SOA     @       root (
                       2013050101      ; serial
                       8H              ; refresh
                       2H              ; retry
                       4W              ; expiry
                       1D              ; minimum
                       )
 
@       IN      NS      @
        IN      A       127.0.0.1
[root@smb4dc named]# vi /var/named/zones/master/0.0.127.zone
 
$TTL 3D
 
@       IN      SOA     localhost. root.localhost. (
                        2013050101      ; Serial
                        8H              ; Refresh
                        2H              ; Retry
                        4W              ; Expire
                        1D              ; Minimum TTL
                        )
 
       IN      NS      localhost.
 
1      IN      PTR     localhost.
```

Set proper file permissions:

```
[root@smb4dc named]# chown named:named /var/named/zones/master/*.zone
[root@smb4dc named]# chmod 640 /var/named/zones/master/*.zone
```

Finally start the daemon:

```
[root@smb4dc named]# named -u named
[root@smb4dc named]# tail -f /var/log/messages
```

Quick status check:

```
[root@smb4dc named]# rndc status
version: 9.9.3-P2
number of zones: 3
debug level: 0
xfers running: 0
xfers deferred: 0
soa queries in progress: 0
query logging is OFF
recursive clients: 0/0/1000
tcp clients: 0/100
server is up and running
```

At the end we need to change the SAMBA settings and tell it to use the external DNS. This is the `BIND9_DLZ` option `--dns-backend=BIND_DLZ` when we set the domain. If we are already on internal DNS and want to move to BIND9_DLZ, then we run `samba_upgradedns` script and configure the BIND DLZ module.

# Client and config test

Some useful commands and tools are given bellow for purpose of status check of our newly running Active Directory server.

```
[root@smb4dc ~]# /usr/local/samba/bin/smbclient --version
Version 4.2.0pre1-GIT-7615b25

[root@smb4dc ~]# /usr/local/samba/bin/smbclient -L localhost -U%
Domain=[ENCOMPASS] OS=[Unix] Server=[Samba 4.2.0pre1-GIT-7615b25]
 
    Sharename       Type      Comment
    ---------       ----      -------
    netlogon        Disk     
    sysvol          Disk     
    IPC$            IPC       IPC Service (Samba 4.2.0pre1-GIT-7615b25)
Domain=[ENCOMPASS] OS=[Unix] Server=[Samba 4.2.0pre1-GIT-7615b25]
 
    Server               Comment
    ---------            -------
 
    Workgroup            Master
    ---------            -------
[root@smb4dc ~]#
```

Global settings:

```
[root@smb4dc samba]# testparm
Load smb config files from /usr/local/samba/etc/smb.conf
rlimit_max: increasing rlimit_max (1024) to minimum Windows limit (16384)
Processing section "[netlogon]"
Processing section "[sysvol]"
Loaded services file OK.
Server role: ROLE_ACTIVE_DIRECTORY_DC
Press enter to see a dump of your service definitions
 
[global]
    workgroup = ENCOMPASS
    realm = ENCOMPASS.COM
    server role = active directory domain controller
    passdb backend = samba_dsdb
    dns forwarder = 8.8.8.8
    rpc_server:tcpip = no
    rpc_daemon:spoolssd = embedded
    rpc_server:spoolss = embedded
    rpc_server:winreg = embedded
    rpc_server:ntsvcs = embedded
    rpc_server:eventlog = embedded
    rpc_server:srvsvc = embedded
    rpc_server:svcctl = embedded
    rpc_server:default = external
    idmap config * : backend = tdb
    map archive = No
    map readonly = no
    store dos attributes = Yes
    vfs objects = dfs_samba4, acl_xattr
 
[netlogon]
    path = /usr/local/samba/var/locks/sysvol/encompass.com/scripts
    read only = No
 
[sysvol]
    path = /usr/local/samba/var/locks/sysvol
    read only = No
[root@smb4dc samba]#

[root@smb4dc ~]# /usr/local/samba/bin/smbclient //localhost/netlogon -UAdministrator% -P -c 'ls'
Domain=[ENCOMPASS] OS=[Unix] Server=[Samba 4.2.0pre1-GIT-7615b25]
  .                                   D        0  Wed Jul 31 07:31:21 2013
  ..                                  D        0  Wed Jul 31 07:31:30 2013
 
        61497 blocks of size 524288. 53831 blocks available
[root@smb4dc ~]#
```

List the own domain:

```
[root@smb4dc samba]# /usr/local/samba/bin/wbinfo --own-domain
ENCOMPASS
```

This is the name (ENCOMPASS) we'll be using in the Windows client set up to join the workstation to the AD.

List Windows Domain users and groups:

```
[root@smb4dc samba]# /usr/local/samba/bin/wbinfo -u
Administrator
Guest
krbtgt
 
[root@smb4dc samba]# /usr/local/samba/bin/wbinfo -g
Enterprise Read-Only Domain Controllers
Domain Admins
Domain Users
Domain Guests
Domain Computers
Domain Controllers
Schema Admins
Enterprise Admins
Group Policy Creator Owners
Read-Only Domain Controllers
DnsUpdateProxy
[root@smb4dc samba]#
```

Check the winbind service is running:

```
[root@smb4dc samba]# /usr/local/samba/bin/wbinfo -p
Ping to winbindd succeeded
```

Check the RPC service:

```
[root@smb4dc samba]# rpcclient localhost -U% -c enumprivs
found 25 privileges
 
SeMachineAccountPrivilege       0:6 (0x0:0x6)
SeTakeOwnershipPrivilege        0:9 (0x0:0x9)
SeBackupPrivilege       0:17 (0x0:0x11)
SeRestorePrivilege      0:18 (0x0:0x12)
SeRemoteShutdownPrivilege       0:24 (0x0:0x18)
SePrintOperatorPrivilege        0:4097 (0x0:0x1001)
SeAddUsersPrivilege         0:4098 (0x0:0x1002)
SeDiskOperatorPrivilege         0:4099 (0x0:0x1003)
SeSecurityPrivilege         0:8 (0x0:0x8)
SeSystemtimePrivilege       0:12 (0x0:0xc)
SeShutdownPrivilege         0:19 (0x0:0x13)
SeDebugPrivilege        0:20 (0x0:0x14)
SeSystemEnvironmentPrivilege        0:22 (0x0:0x16)
SeSystemProfilePrivilege        0:11 (0x0:0xb)
SeProfileSingleProcessPrivilege         0:13 (0x0:0xd)
SeIncreaseBasePriorityPrivilege         0:14 (0x0:0xe)
SeLoadDriverPrivilege       0:10 (0x0:0xa)
SeCreatePagefilePrivilege       0:15 (0x0:0xf)
SeIncreaseQuotaPrivilege        0:5 (0x0:0x5)
SeChangeNotifyPrivilege         0:23 (0x0:0x17)
SeUndockPrivilege       0:25 (0x0:0x19)
SeManageVolumePrivilege         0:28 (0x0:0x1c)
SeImpersonatePrivilege      0:29 (0x0:0x1d)
SeCreateGlobalPrivilege         0:30 (0x0:0x1e)
SeEnableDelegationPrivilege         0:27 (0x0:0x1b)
```

# Managing SAMBA AD from Windows

Install Win7/WinXP or similar and, this is very important, set the DNS server to the IP of the Samba4 AD in the network interface configuration. Then join the workstation to the ENCOMPASS domain (see screen shots).

When "Network ID" clicked, enter AD user name and ENCOMPASS for domain name in the fields and click OK. If all good you will be presented with the AD domain welcome screen as confirmation of successfully joining the domain. Restart the PC and you should get a Login screen now where you enter your Domain user name and password and choose "ENCOMPASS" in the "Login to:" drop box:

After installing WIn7 or WinXP in my case, we follow the links given on the [Samba support page](https://wiki.samba.org/index.php/Samba_AD_management_from_windows)

Basically, install the RSAT tools from:

```
http://www.microsoft.com/downloads/en/details.aspx?FamilyID=86b71a4f-4122-44af-be79-3f101e533d95
http://download.microsoft.com/download/3/e/4/3e438f5e-24ef-4637-abd1-981341d349c7/WindowsServer2003-KB892777-SupportTools-x86-ENU.exe
```

and start the `Acite Directory Management` from Amdin Tools:

That's it, now we have fully flagged Active Directory server and Windows Management UI where we can set and edit users, groups, shares and policies. The same Manager can be used for AD DNS administration ie creating or editing zones and records.
