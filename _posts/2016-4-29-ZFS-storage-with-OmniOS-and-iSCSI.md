---
type: posts
header:
  teaser: 'omnios.jpg'
title: 'ZFS storage with OmniOS and iSCSI'
categories: 
  - High-Availability
tags: [zfs, iscsi, high-availability]
date: 2016-8-29
---
{% include toc %}
The following setup of iSCSI shared storage on cluster of OmniOS servers was later used as `ZFS over iSCSI` storage in `Proxmox PVE`, see [Adding ZFS over iSCSI shared storage to Proxmox]({{ site.baseurl }}{% post_url 2016-9-19-Adding-iSCSI-shared-volume-to-Proxmox-to-support-Live-Migration %}). It was inspired by the excellent work from [Saso Kiselkov](http://zfs-create.blogspot.com.au) and his `stmf-ha` project, please see the References section at the bottom of this page for details.

[OmniOS](https://omnios.omniti.com/) is an open source continuation of OpenSolaris (discontinued by Oracle when they acquired Sun Microsystems back in 2010) that builds on [IllumOS](http://illumos.org/) project, the OpenSolaris reincarnation. ZFS and iSCSI, or COMSTAR (Common Multiprotocol SCSI Target), have been part of Solaris for very long time bringing performance and stability to the storage solution.

For the setup I'm using two VM's, `omnios01` and `omnios02`, connected via two networks, public `192.168.0.0/24` and private `10.10.1.0/24` one configured on the hypervisor.

## OmniOS installation and initial setup

Download the current [stable OmniOS iso](http://omnios.omniti.com/media/OmniOS_Text_r151018.iso), and launch a VM in Proxmox. Start it up and install accepting the defaults. 

Change GRUB default timeout on boot from 30 to 5 seconds:

```
root@omnios01:/root# vi /rpool/boot/grub/menu.lst
...
timeout 5
...
```

Try telling OmniOS we have 2 virtual cpu's:

```
root@omnios01:/root# eeprom boot-ncpus=2
root@omnios01:/root# psrinfo -vp
The physical processor has 1 virtual processor (0)
  x86 (GenuineIntel F61 family 15 model 6 step 1 clock 1900 MHz)
        Common KVM processor
```

when we have 1 CPU (socket) with 2 cores.

Then configure networking:

```
root@omnios01:/root# ipadm create-if e1000g0
root@omnios01:/root# ipadm create-addr -T static -a local=192.168.0.141/24 e1000g0/v4
root@omnios01:/root# route -p add default 192.168.0.1
root@omnios01:/root# echo 'nameserver 192.168.0.1' >> /etc/resolv.conf
root@omnios01:/root# cp /etc/nsswitch.dns /etc/nsswitch.conf
root@omnios01:/root# ipadm show-addr
ADDROBJ           TYPE     STATE        ADDR
lo0/v4            static   ok           127.0.0.1/8
e1000g0/v4        static   ok           192.168.0.141/24
lo0/v6            static   ok           ::1/128
```

Secondary interface:

```
root@omnios01:/root# ipadm create-if e1000g1
root@omnios01:/root# ipadm create-addr -T dhcp e1000g1/dhcp
root@omnios01:/root# ipadm show-addr
ADDROBJ           TYPE     STATE        ADDR
lo0/v4            static   ok           127.0.0.1/8
e1000g0/v4        static   ok           192.168.0.141/24
e1000g1/dhcp      dhcp     ok           10.10.1.13/24
lo0/v6            static   ok           ::1/128
```

If we want to enable jumbo frames and we have a switch that supports it:

```
root@omnios01:/root# dladm set-linkprop -p mtu=9000 e1000go
```

Configure the hosts file:

* on omnios01

  ```
  127.0.0.1       omnios01
  10.10.1.12      omnios02
  ```

* on omnios02

  ```
  127.0.0.1       omnios02
  10.10.1.13      omnios01
  ```

Configure SSH to allow both ssh key and password login for root user:

```
root@omnios01:/root# cat /etc/ssh/sshd_config | grep -v ^# | grep .
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin yes
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile      .ssh/authorized_keys
HostbasedAuthentication no
IgnoreRhosts yes
PasswordAuthentication yes 
PermitEmptyPasswords no
ChallengeResponseAuthentication no
GSSAPIAuthentication no 
UsePAM yes 
PrintMotd no
TCPKeepAlive yes
UseDNS no
Subsystem       sftp    /usr/libexec/sftp-server
AllowUsers root
```

and restart ssh service:

```
root@omnios01:/root# svcadm restart svc:/network/ssh:default
```

Next check if the STMF service is running:

```
root@omnios01:/root# svcs -l stmf
fmri         svc:/system/stmf:default
name         STMF
enabled      true
state        online
next_state   none
state_time   25 August 2016 05:06:30 AM UTC
logfile      /var/svc/log/system-stmf:default.log
restarter    svc:/system/svc/restarter:default
dependency   require_all/none svc:/system/filesystem/local:default (online)
```

and if not enable it:

```
root@omnios01:/root# svcadm enable stmf
```

Then enable COMSTAR iSCSI target service from the GUI or console:

```
root@omnios01:/root# svcadm enable -r svc:/network/iscsi/target:default
root@omnios01:/root# svcs -l iscsi/target
fmri         svc:/network/iscsi/target:default
name         iscsi target
enabled      true
state        online
next_state   none
state_time   25 August 2016 05:06:31 AM UTC
logfile      /var/svc/log/network-iscsi-target:default.log
restarter    svc:/system/svc/restarter:default
dependency   require_any/error svc:/milestone/network (online)
dependency   require_all/none svc:/system/stmf:default (online)
```

If the services are missing we need to install the `storage-server` package:

```
# pkg install group/feature/storage-server
# svcadm enable stmf
```

The following 3 SATA (have to be on SATA bus for VM's, not sure why) disks, apart from the root one, have been attached to each VM:

```
root@omnios01:/root# format
Searching for disks...done

AVAILABLE DISK SELECTIONS:
       0. c2t0d0 <QEMU-HARDDISK-1.4.2 cyl 2085 alt 2 hd 255 sec 63>
          /pci@0,0/pci1af4,1100@7/disk@0,0
       1. c2t1d0 <QEMU-HARDDISK-1.4.2-10.00GB>
          /pci@0,0/pci1af4,1100@7/disk@1,0
       2. c2t2d0 <QEMU-HARDDISK-1.4.2-10.00GB>
          /pci@0,0/pci1af4,1100@7/disk@2,0
       3. c2t3d0 <QEMU-HARDDISK-1.4.2-10.00GB>
          /pci@0,0/pci1af4,1100@7/disk@3,0
Specify disk (enter its number): ^C
root@omnios01:/root#
```

They will be used to create a new zfs pool named `pool1` from these 3x10GB disks using RAIDZ1 mirror that I will then use in my ZFS over iSCSI setup in the PVE cluster.

## iSCSI HA

### HA packages and stmf-ha setup

Install pre-built HA packages (HeartBeat, Cluster Glue, Pacemaker, OCF Agents) from the bundle created by Saso Kiselkov at (http://zfs-create.blogspot.com.au):

```
root@omnios01:/root# wget http://37.153.99.61/HA.tar.bz2
root@omnios01:/root# tar -xjvf HA.tar.bz2
root@omnios01:/root# cd HA/prebuilt_packages
root@omnios01:/root# gunzip *.gz
root@omnios01:/root# for PKG in *.pkg ; do pkgadd -d $PKG ; done
root@omnios01:/root# vi ~/.profile 
[...]
export PYTHONPATH=/opt/ha/lib/python2.6/site-packages
export PATH=/opt/ha/bin:/opt/ha/sbin:$PATH
export OCF_ROOT=/opt/ha/lib/ocf
export OCF_AGENTS=/opt/ha/lib/ocf/resource.d/heartbeat

root@omnios01:/root# pkg install ipmitool
root@omnios01:/root# pkg install git
root@omnios01:/root# git clone https://github.com/skiselkov/stmf-ha.git
Cloning into 'stmf-ha'...
remote: Counting objects: 72, done.
remote: Total 72 (delta 0), reused 0 (delta 0), pack-reused 72
Unpacking objects: 100% (72/72), done.
Checking connectivity... done.

root@omnios01:/root# cp stmf-ha/heartbeat/ZFS /opt/ha/lib/ocf/resource.d/heartbeat/
root@omnios01:/root# chmod +x /opt/ha/lib/ocf/resource.d/heartbeat/ZFS
root@omnios01:/root# perl -pi -e 's/#DEBUG=0/DEBUG=1/' /opt/ha/lib/ocf/resource.d/heartbeat/ZFS
root@omnios01:/root# mkdir -p /opt/ha/lib/ocf/lib/heartbeat/helpers
root@omnios01:/root# cp stmf-ha/heartbeat/zfs-helper /opt/ha/lib/ocf/lib/heartbeat/helpers/
root@omnios01:/root# chmod +x /opt/ha/lib/ocf/lib/heartbeat/helpers/zfs-helper
root@omnios01:/root# cp stmf-ha/stmf-ha /usr/sbin/
root@omnios01:/root# chmod +x /usr/sbin/stmf-ha
root@omnios01:/root# cp stmf-ha/manpages/stmf-ha.1m /usr/share/man/man1m/
root@omnios01:/root# man stmf-ha
```

Fix annoying `ps` command error for `crm`:

```
root@omnios01:/root# perl -pi -e 's#ps -e -o pid,command#ps -e -o pid,comm#' /opt/ha/lib/python2.6/site-packages/crm/utils.py
```

Fix the IPaddr OCF agent, get patched one from Vincenco's site see [Use pacemaker and corosync on Illumos (OmniOS) to run a HA active/passive cluster](https://blog.zhaw.ch/icclab/use-pacemaker-and-corosync-on-illumos-omnios-to-run-a-ha-activepassive-cluster/) for details:

```
root@omnios01:/root# cp /opt/ha/lib/ocf/resource.d/heartbeat/IPaddr /opt/ha/lib/ocf/resource.d/heartbeat/IPaddr.default
root@omnios01:/root# wget -O /opt/ha/lib/ocf/resource.d/heartbeat/IPaddr https://gist.githubusercontent.com/vincepii/6763170efa5050d2d73d/raw/bfc0e7df7dda9c673b4e0888240581f7963ff1b6/IPaddr
```

### Configure HeartBeat

Create the config file, we can edit the example on the project site.

Based on Saso's config from the git repo with serial link between nodes for heart beat I ended up with the following `/opt/ha/etc/ha.d/ha.cf` config file:

```
# Master Heartbeat configuration file
# This file must be identical on all cluster nodes

# GLOBAL OPTIONS
use_logd        yes             # Logging done in separate process to
                                # prevent blocking on disk I/O
baud            38400           # Run the serial link at 38.4 kbaud
realtime        on              # Enable real-time scheduling and lock
                                # heartbeat into memory to prevent its
                                # pages from ever being swapped out

apiauth cl_status gid=haclient uid=hacluster

# NODE LIST SETUP
# Node names depend on the machine's host name. To protect against
# accidental joins from nodes that are part of other zfsstor clusters
# we do not allow autojoins (plus we use shared-secret authentication).
node            omnios01
node            omnios02
autojoin        none
auto_failback   off

# COMMUNICATION CHANNEL SETUP
#mcast   e1000g0    239.51.12.1 694 1 0     # management network
#mcast   e1000g1    239.51.12.1 694 1 0     # dedicated NIC between nodes
mcast   e1000g0    239.0.0.43 694 1 0
bcast   e1000g1    # dedicated NIC between nodes

# STONITH/FENCING IN CASE OR REAL NODES
# Use ipmi to check power status and reboot nodes
#stonith_host    omnios01 external/ipmi omnios02 192.168.0.141 <ipmi_admin_username> <ipmi_admin_password> lan
#stonith_host    omnios02 external/ipmi omnios01 192.168.0.142 <ipmi_admin_username> <ipmi_admin_password> lan

# NODE FAILURE DETECTION
keepalive       2       # Heartbeats every 2 second
warntime        5       # Start issuing warnings after 5 seconds
deadtime        15      # After 15 seconds, a node is considered dead
initdead        60      # Hold off declaring nodes dead for 60 seconds
                        # after Heartbeat startup.

# Enable the Pacemaker CRM
crm                     on
#compression             bz2
#traditional_compression yes
```

To find the list of available STONITH devices run:

```
root@omnios02:/root# stonith -L
apcmaster
apcmastersnmp
apcsmart
baytech
cyclades
drac3
external/drac5
external/dracmc-telnet
external/hetzner
external/hmchttp
external/ibmrsa
external/ibmrsa-telnet
external/ipmi
external/ippower9258
external/kdumpcheck
external/libvirt
external/nut
external/rackpdu
external/riloe
external/sbd
external/ssh
external/vcenter
external/vmware
external/xen0
external/xen0-ha
ibmhmc
meatware
null
nw_rpc100s
rcd_serial
rps10
ssh
suicide
wti_mpc
wti_nps
root@omnios02:/root#
```

and add it to configuration if you have one.

Create the authentication file:

```
root@omnios01:/root# (echo -ne "auth 1\n1 sha1 "; openssl rand -rand /dev/random -hex 16 2> /dev/null) > /opt/ha/etc/ha.d/authkeys
```

Grant sudo access to the `hacluster` user (on both nodes):

```
root@omnios01:/root/HA# visudo
[...]
hacluster    ALL=(ALL) NOPASSWD: ALL
```

Create the `logd` config file:

```
root@omnios01:/root/HA# cat /opt/ha/etc/logd.cf
#       File to write debug messages to
#       Default: /var/log/ha-debug
debugfile /var/log/ha-debug

#
#
#       File to write other messages to
#       Default: /var/log/ha-log
logfile        /var/log/ha-log

#
#
#       Octal file permission to create the log files with
#       Default: 0644
logmode        0640


#
#
#       Facility to use for syslog()/logger 
#   (set to 'none' to disable syslog logging)
#       Default: daemon
logfacility    daemon


#       Entity to be shown at beginning of a message
#       generated by the logging daemon itself
#       Default: "logd"
#entity logd


#       Entity to be shown at beginning of _every_ message
#       passed to syslog (not to log files).
#
#       Intended for easier filtering, or safe blacklisting.
#       You can filter on logfacility and this prefix.
#
#       Message format changes like this:
#       -Nov 18 11:30:31 soda logtest: [21366]: info: total message dropped: 0
#       +Nov 18 11:30:31 soda common-prefix: logtest[21366]: info: total message dropped: 0
#
#       Default: none (disabled)
#syslogprefix linux-ha


#       Do we register to apphbd
#       Default: no
#useapphbd no

#       There are two processes running for logging daemon
#               1. parent process which reads messages from all client channels 
#               and writes them to the child process 
#  
#               2. the child process which reads messages from the parent process through IPC
#               and writes them to syslog/disk


#       set the send queue length from the parent process to the child process
#
#sendqlen 256 

#       set the recv queue length in child process
#
#recvqlen 256
```

and enable the service:

```
root@omnios01:/root/HA# svcadm enable ha_logd
```

Finally start the HA service on both servers omnios01 and omnios02 and check the status:

```
root@omnios02:/root# /opt/ha/lib/heartbeat/heartbeat
heartbeat[3153]: 2016/08/26_06:30:47 info: Enabling logging daemon 
heartbeat[3153]: 2016/08/26_06:30:47 info: logfile and debug file are those specified in logd config file (default /etc/logd.cf)
heartbeat[3153]: 2016/08/26_06:30:47 info: Pacemaker support: on
heartbeat[3153]: 2016/08/26_06:30:47 info: **************************
heartbeat[3153]: 2016/08/26_06:30:47 info: Configuration validated. Starting heartbeat 3.0.5
root@omnios02:/root# 
```

and verify the cluster state:

```
root@omnios02:/root# crm status
============
Last updated: Fri Aug 26 06:30:54 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
0 Resources configured.
============

Online: [ omnios01 omnios02 ]

root@omnios02:/root#
```

After we confirm it is working fine we can kill the above started process and enable the service:

```
root@omnios01:/root# svcadm enable heartbeat
root@omnios01:/root# svcs -a | grep heart
online          7:48:21 svc:/application/cluster/heartbeat:default
```

Next we set some parameters for 2 node cluster, ie disable quorum and `stonith` since this is in vm's:

```
root@omnios01:/root# crm configure property no-quorum-policy=ignore
root@omnios01:/root# crm configure property stonith-enabled="false"
root@omnios01:/root# crm configure property stonith-action=poweroff
```

and set some values for resource stickiness (default zero, will move immediately) and migration threshold (default none, will try forever on the same node):

```
root@omnios01:/root# crm configure rsc_defaults resource-stickiness=100
root@omnios01:/root# crm configure rsc_defaults migration-threshold=3
 
root@omnios01:/root# crm configure show
node $id="11dc182d-5096-cd7c-acc6-eb3b3493f314" omnios01
node $id="641f06f8-65a9-44fd-80f4-96b87e9c4062" omnios02
property $id="cib-bootstrap-options" \
        dc-version="1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04" \
        cluster-infrastructure="Heartbeat" \
        no-quorum-policy="ignore" \
        stonith-enabled="false" \
        last-lrm-refresh="1472435153" \
        stonith-action="poweroff"
rsc_defaults $id="rsc-options" \
        resource-stickiness="100" \
        migration-threshold="3"
root@omnios01:/root# 
```

Create the first resource, the cluster VIP address:

```
root@omnios01:/root# crm configure
crm(live)configure# primitive p_pool1_VIP ocf:heartbeat:IPaddr \
>         params ip="10.10.1.205" cidr_netmask="24" nic="e1000g1" \
>         op monitor interval="10s" \
>         meta target-role="Started"
crm(live)configure# verify
crm(live)configure# commit
crm(live)configure# exit
```

and check the status again:

```
root@omnios01:/root# crm status
============
Last updated: Fri Aug 26 10:56:23 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
1 Resources configured.
============

Online: [ omnios01 omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios01
root@omnios01:/root#
```

and if we check the links on the server we can see the VIP:

```
root@omnios01:/root# ipadm show-addr
ADDROBJ           TYPE     STATE        ADDR
lo0/v4            static   ok           127.0.0.1/8
e1000g0/v4        static   ok           192.168.0.141/24
e1000g1/cr        static   ok           10.10.1.205/24
lo0/v6            static   ok           ::1/128
```

In case we want to preserve the primary IP of the `e1000g1` interface instead overwriting it with the VIP one we can create a VNIC and use it for the VIP:

```
root@omnios01:/root# dladm create-vnic -l e1000g1 VIP1
root@omnios01:/root# dladm show-link
LINK        CLASS     MTU    STATE    BRIDGE     OVER
e1000g0     phys      1500   up       --         --
e1000g1     phys      1500   up       --         --
VIP1        vnic      1500   up       --         e1000g1

crm(live)configure# primitive p_pool1_VIP ocf:heartbeat:IPaddr \
         params ip="10.10.1.205" cidr_netmask="24" nic="VIP1" \
         op monitor interval="10s" \
         meta target-role="Started"

root@omnios01:/root# crm configure show
node $id="11dc182d-5096-cd7c-acc6-eb3b3493f314" omnios01 \
        attributes standby="off" online="on"
node $id="641f06f8-65a9-44fd-80f4-96b87e9c4062" omnios02
primitive p_pool1_VIP ocf:heartbeat:IPaddr \
        params ip="10.10.1.205" cidr_netmask="24" nic="VIP1" \
        op monitor interval="10s" \
        meta target-role="Started"
property $id="cib-bootstrap-options" \
        dc-version="1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04" \
        cluster-infrastructure="Heartbeat" \
        no-quorum-policy="ignore" \
        stonith-enabled="false" \
        last-lrm-refresh="1472435153" \
        stonith-action="poweroff"
root@omnios01:/root# 

root@omnios01:/root# ipadm show-addr
ADDROBJ           TYPE     STATE        ADDR
lo0/v4            static   ok           127.0.0.1/8
e1000g0/v4        static   ok           192.168.0.141/24
e1000g1/dhcp      dhcp     ok           10.10.1.13/24
VIP1/cr           static   ok           10.10.1.205/24
lo0/v6            static   ok           ::1/128
```

which is the way I ended up doing it.

Now we can create our ZFS pool:

```
root@omnios01:/root# zpool create -m /pool1 -o autoexpand=on -o autoreplace=on -o cachefile=none pool1 raidz c2t1d0 c2t2d0 c2t3d0
root@omnios01:/root# zpool status pool1
  pool: pool1
 state: ONLINE
  scan: none requested
config:

        NAME        STATE     READ WRITE CKSUM
        pool1       ONLINE       0     0     0
          raidz1-0  ONLINE       0     0     0
            c2t1d0  ONLINE       0     0     0
            c2t2d0  ONLINE       0     0     0
            c2t3d0  ONLINE       0     0     0

errors: No known data errors
root@omnios01:/root#
```

and set some parameters like `lz4` compression:

```
root@omnios01:/root# zpool set feature@lz4_compress=enabled pool1
root@omnios01:/root# zfs set compression=lz4 pool1
root@omnios01:/root# zfs set atime=off pool1
root@omnios01:/root# zfs list pool1
NAME    USED  AVAIL  REFER  MOUNTPOINT
pool1  5.33G  13.9G  28.0K  /pool1
```

after that we have the following state:

```
root@omnios01:/root# zfs get all pool1
NAME   PROPERTY              VALUE                  SOURCE
pool1  type                  filesystem             -
pool1  creation              Mon Aug 29  5:56 2016  -
pool1  used                  5.33G                  -
pool1  available             13.9G                  -
pool1  referenced            28.0K                  -
pool1  compressratio         1.12x                  -
pool1  mounted               yes                    -
pool1  quota                 none                   default
pool1  reservation           none                   default
pool1  recordsize            128K                   default
pool1  mountpoint            /pool1                 local
pool1  sharenfs              off                    default
pool1  checksum              on                     default
pool1  compression           lz4                    local
pool1  atime                 off                    local
pool1  devices               on                     default
pool1  exec                  on                     default
pool1  setuid                on                     default
pool1  readonly              off                    default
pool1  zoned                 off                    default
pool1  snapdir               hidden                 default
pool1  aclmode               discard                default
pool1  aclinherit            restricted             default
pool1  canmount              on                     default
pool1  xattr                 on                     default
pool1  copies                1                      default
pool1  version               5                      -
pool1  utf8only              off                    -
pool1  normalization         none                   -
pool1  casesensitivity       sensitive              -
pool1  vscan                 off                    default
pool1  nbmand                off                    default
pool1  sharesmb              off                    default
pool1  refquota              none                   default
pool1  refreservation        none                   default
pool1  primarycache          all                    default
pool1  secondarycache        all                    default
pool1  usedbysnapshots       0                      -
pool1  usedbydataset         28.0K                  -
pool1  usedbychildren        5.33G                  -
pool1  usedbyrefreservation  0                      -
pool1  logbias               latency                default
pool1  dedup                 off                    default
pool1  mlslabel              none                   default
pool1  sync                  standard               default
pool1  refcompressratio      1.00x                  -
pool1  written               28.0K                  -
pool1  logicalused           6.00G                  -
pool1  logicalreferenced     13.5K                  -
pool1  filesystem_limit      none                   default
pool1  snapshot_limit        none                   default
pool1  filesystem_count      none                   default
pool1  snapshot_count        none                   default
pool1  redundant_metadata    all                    default
root@omnios01:/root# 

root@omnios01:/root# zfs mount
rpool/ROOT/omnios               /
rpool/export                    /export
rpool/export/home               /export/home
rpool                           /rpool
pool1                           /pool1

root@omnios01:/root# mount | grep pool1
/pool1 on pool1 read/write/setuid/devices/nonbmand/exec/xattr/atime/dev=42d0012 on Mon Aug 29 05:56:18 2016
```

Next step is to copy over the `stmf-ha` config file so pacemaker can take control over COMSTAR resources:

```
root@omnios01:/root# cp stmf-ha/samples/stmf-ha-sample.conf /pool1/stmf-ha.conf
```

Now we can create the resource in pacemaker:

```
primitive p_zfs_pool1 ocf:heartbeat:ZFS \
  params pool="pool1" \
  op start timeout="90" \
  op stop timeout="90"
colocation col_pool1_with_VIP inf: p_zfs_pool1 p_pool1_VIP
order o_pool1_before_VIP inf: p_zfs_pool1 p_pool1_VIP
```

After committing the changes we need to start the resource on the node we created the pool on, in this case omnios01:

```
root@omnios01:/root# crm resource start p_zfs_pool1
```

after which we can see:

```
root@omnios01:/root# crm status
============
Last updated: Mon Aug 29 03:39:39 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
2 Resources configured.
============

Online: [ omnios01 omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios01
 p_zfs_pool1    (ocf::heartbeat:ZFS):   Started omnios01
root@omnios01:/root# 
```

Now we can create `ZFS over iSCSI` resource in `Proxmox` using the VIP address as portal. I created a vm with id of 109 in Proxmox which resulted with the `pool1/vm-109-disk-1` zvol being created on the OmniOS cluster.

The last step is enabling the compression on the VM root device after we have created it so we can benefit from this feature:

```
root@omnios01:/root# zfs set compression=lz4 pool1/vm-109-disk-1
root@omnios01:/root# zfs get all pool1/vm-109-disk-1
NAME                 PROPERTY                  VALUE                             SOURCE
pool1/vm-109-disk-1  type                      volume                            -
pool1/vm-109-disk-1  creation                  Mon Aug 29  6:13 2016             -
pool1/vm-109-disk-1  used                      5.33G                             -
pool1/vm-109-disk-1  available                 13.9G                             -
pool1/vm-109-disk-1  referenced                5.33G                             -
pool1/vm-109-disk-1  compressratio             1.12x                             -
pool1/vm-109-disk-1  reservation               none                              default
pool1/vm-109-disk-1  volsize                   6G                                local
pool1/vm-109-disk-1  volblocksize              64K                               -
pool1/vm-109-disk-1  checksum                  on                                default
pool1/vm-109-disk-1  compression               lz4                               local
pool1/vm-109-disk-1  readonly                  off                               default
pool1/vm-109-disk-1  copies                    1                                 default
pool1/vm-109-disk-1  refreservation            none                              default
pool1/vm-109-disk-1  primarycache              all                               default
pool1/vm-109-disk-1  secondarycache            all                               default
pool1/vm-109-disk-1  usedbysnapshots           0                                 -
pool1/vm-109-disk-1  usedbydataset             5.33G                             -
pool1/vm-109-disk-1  usedbychildren            0                                 -
pool1/vm-109-disk-1  usedbyrefreservation      0                                 -
pool1/vm-109-disk-1  logbias                   latency                           default
pool1/vm-109-disk-1  dedup                     off                               default
pool1/vm-109-disk-1  mlslabel                  none                              default
pool1/vm-109-disk-1  sync                      standard                          default
pool1/vm-109-disk-1  refcompressratio          1.12x                             -
pool1/vm-109-disk-1  written                   5.33G                             -
pool1/vm-109-disk-1  logicalused               6.00G                             -
pool1/vm-109-disk-1  logicalreferenced         6.00G                             -
pool1/vm-109-disk-1  snapshot_limit            none                              default
pool1/vm-109-disk-1  snapshot_count            none                              default
pool1/vm-109-disk-1  redundant_metadata        all                               default
pool1/vm-109-disk-1  org.illumos.stmf-ha:lun   1                                 local
pool1/vm-109-disk-1  org.illumos.stmf-ha:guid  600144F721dca2888ba402e411ee3af1  local
root@omnios01:/root# 
```

Get the I/O stats for the pool:

```
root@omnios02:/root# zpool iostat -v
               capacity     operations    bandwidth
pool        alloc   free   read  write   read  write
----------  -----  -----  -----  -----  -----  -----
pool1        216K  29.7G      0      0      0      1
  raidz1     216K  29.7G      0      0      0      1
    c2t1d0      -      -      0      0      6      5
    c2t2d0      -      -      0      0      5      5
    c2t3d0      -      -      0      0      5      5
----------  -----  -----  -----  -----  -----  -----
rpool       5.74G  10.1G      0      3    123  23.9K
  c2t0d0s0  5.74G  10.1G      0      3    123  23.9K
----------  -----  -----  -----  -----  -----  -----
```

We can also see a COMSTAR target has been created:

```
root@omnios01:/root# itadm list-target -v
TARGET NAME                                                  STATE    SESSIONS 
iqn.2010-08.org.illumos:stmf-ha:pool1                        online   0        
        alias:                  -
        auth:                   none (defaults)
        targetchapuser:         -
        targetchapsecret:       unset
        tpg-tags:               default
```

and the LUN for the Proxmox VM:

```
root@omnios01:/root# sbdadm list-lu
Found 1 LU(s)
              GUID                    DATA SIZE           SOURCE
--------------------------------  -------------------  ----------------
600144f721dca2888ba402e411ee3af1  6442450944           /dev/zvol/rdsk/pool1/vm-109-disk-1

root@omnios01:/root# stmfadm list-lu -v
LU Name: 600144F721DCA2888BA402E411EE3AF1
    Operational Status: Online
    Provider Name     : sbd
    Alias             : /dev/zvol/rdsk/pool1/vm-109-disk-1
    View Entry Count  : 1
    Data File         : /dev/zvol/rdsk/pool1/vm-109-disk-1
    Meta File         : not set
    Size              : 6442450944
    Block Size        : 512
    Management URL    : not set
    Vendor ID         : SUN     
    Product ID        : COMSTAR         
    Serial Num        : not set
    Write Protect     : Disabled
    Writeback Cache   : Disabled
    Access State      : Active

root@omnios01:/root# zfs list -rH -t volume pool1 
pool1/vm-109-disk-1     3.87G   15.3G   3.87G   -
```

### Install `napp-it` ZFS appliance (optional)

In this case we don't really need napp-it, we just need to launch 2 x OmniOS instances and install and configure the HA. Napp-it can help though for managing snapshots, clones, backups, rollbacks etc. for which having a web GUI should help a lot.

```
root@omnios01:/root# wget -O - www.napp-it.org/nappit | perl
```

and then connect to the web UI `http://serverip:81` when finished. Reboot after installation of `napp-it` then update napp-it (Menu About -> Update) or run:

```
root@omnios01:/root# pkg update
```

## Moving the resources from one node to another manually

We put the node the resource is running on into standby mode:

```
root@omnios01:/root# crm node attribute omnios01 set standby on

root@omnios01:/root# crm status
============
Last updated: Mon Aug 29 02:10:59 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
1 Resources configured.
============

Node omnios01 (11dc182d-5096-cd7c-acc6-eb3b3493f314): standby
Online: [ omnios02 ]

root@omnios01:/root# crm status
============
Last updated: Mon Aug 29 02:11:03 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
1 Resources configured.
============

Node omnios01 (11dc182d-5096-cd7c-acc6-eb3b3493f314): standby
Online: [ omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios02
```

and after couple of seconds we can see the VIP has moved to omnios02.

```
root@omnios02:/root# ipadm show-addr
ADDROBJ           TYPE     STATE        ADDR
lo0/v4            static   ok           127.0.0.1/8
e1000g0/v4        static   ok           192.168.0.142/24
e1000g1/dhcp      dhcp     ok           10.10.1.12/24
VIP1/cr           static   ok           10.10.1.205/24
lo0/v6            static   ok           ::1/128
```

Another test with all resources created:

```
root@omnios01:/root# crm status
============
Last updated: Tue Aug 30 07:10:25 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
2 Resources configured.
============

Online: [ omnios01 omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios01
 p_zfs_pool1    (ocf::heartbeat:ZFS):   Started omnios01
root@omnios01:/root#

root@omnios01:/root# crm node attribute omnios01 set standby on

root@omnios01:/root# crm status
============
Last updated: Tue Aug 30 07:14:22 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
2 Resources configured.
============

Node omnios01 (11dc182d-5096-cd7c-acc6-eb3b3493f314): standby
Online: [ omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios02
 p_zfs_pool1    (ocf::heartbeat:ZFS):   Started omnios02
root@omnios01:/root#
```

To bring the node online again we run:

```
root@omnios01:/root# crm node attribute omnios01 set standby off
```

Then we can check the status again:

```
root@omnios01:/root# crm status
============
Last updated: Mon Aug 29 02:14:42 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
1 Resources configured.
============

Online: [ omnios01 omnios02 ]

root@omnios01:/root# crm status
============
Last updated: Mon Aug 29 02:14:48 2016
Stack: Heartbeat
Current DC: omnios02 (641f06f8-65a9-44fd-80f4-96b87e9c4062) - partition with quorum
Version: 1.0.11-6e010d6b0d49a6b929d17c0114e9d2d934dc8e04
2 Nodes configured, unknown expected votes
1 Resources configured.
============

Online: [ omnios01 omnios02 ]

 p_pool1_VIP    (ocf::heartbeat:IPaddr):        Started omnios01
```

and after couple of seconds we can see that omnios01 is back online and the VIP has moved back to omnios01. After setting `resource-stickiness=100` though the resources will stay on omnios02.

> Please note that I'm **NOT** using a shared storage for the cluster hence the ZFS resource failover can **NOT** work.


## References

* [Building zfs storage appliance part-1](http://zfs-create.blogspot.com.au/2013/06/building-zfs-storage-appliance-part-1.html)
* [Building zfs storage appliance part-2](http://zfs-create.blogspot.com.au/2014/05/building-zfs-storage-appliance-part-2.html)
* [Use pacemaker and corosync on Illumos (OmniOS) to run a HA active/passive cluster](https://blog.zhaw.ch/icclab/use-pacemaker-and-corosync-on-illumos-omnios-to-run-a-ha-activepassive-cluster/)
* [ZFS iSCSI Configuration](https://www.highlnk.com/2014/04/zfs-iscsi-configuration/)
* [Configuring iSCSI Devices With COMSTAR](https://docs.oracle.com/cd/E23824_01/html/821-1459/fnnop.html)

## APPENDIX

At the end some commands related to ZFS and COMSTAR that I find useful.

### COMSTAR COMMANDS

#### Install COMSTAR

```
# pkg install group/feature/storage-server
# svcadm enable stmf
```

#### Target related

```
# svcadm enable -r svc:/network/iscsi/target:default
# itadm create-target iqn.2010-09.org.napp-it:tgt1
# itadm list-target -v
# stmfadm offline-target iqn.2010-09.org.napp-it:tgt1
# itadm delete-target iqn.2010-09.org.napp-it:tgt1
```

#### TPG (Target Portal Group)

```
# itadm create-tpg TPGA 10.10.1.205 10.20.1.205
# itadm list-tpg -v
# itadm modify-target -t PTGA,TPGB iqn.2010-09.org.napp-it:tgt1
```

#### LUN

```
# zpool create sanpool mirror c2t3d0 c2t4d0 
# zfs create -V 10g sanpool/vol1
# stmfadm create-lu /dev/zvol/rdisk/sanpool/vol1
# stmfadm list-lu -v

e.g. 
root@omnios01:/root# stmfadm list-lu -v
LU Name: 600144F721DCA2888BA402E411EE3AF1
    Operational Status: Online
    Provider Name     : sbd
    Alias             : /dev/zvol/rdsk/pool1/vm-109-disk-1
    View Entry Count  : 1
    Data File         : /dev/zvol/rdsk/pool1/vm-109-disk-1
    Meta File         : not set
    Size              : 6442450944
    Block Size        : 512
    Management URL    : not set
    Vendor ID         : SUN     
    Product ID        : COMSTAR         
    Serial Num        : not set
    Write Protect     : Disabled
    Writeback Cache   : Disabled
    Access State      : Active
```

#### TG (Target Group)

```
# stmfadm create-tg targets-0
# stmfadm add-tg-member -g targets-0 iqn.2010-09.org.napp-it:tgt1
```

#### HG (Host Group)

```
# stmfadm create-hg host-a <WWN space delimited number(s) of the initiator device (iSCSI,HBA etc.)>
# stmfadm add-hg-member -g host-a <WWN number of another initiator device (iSCSI,HBA etc.)>
```

#### LUN accsess rights via View

LUN is available to all:

```
# stmfadm add-view 600144F721DCA2888BA402E411EE3AF1
# stmfadm list-view -l 600144F721DCA2888BA402E411EE3AF1
```

LUN is available to specific host group:

```
# stmfadm add-view -h host-a -t 600144F721DCA2888BA402E411EE3AF1
```

### ZFS COMMANDS

Tunable ZFS parameters, most of these can be set in `/etc/system`:

  ```
  # echo "::zfs_params" | mdb -k
  ```

  Some settings and mostly statistics on ARC usage:

  ```
  # echo "::arc" | mdb -k
  ```

  Solaris memory allocation; "Kernel" memory includes ARC:

  ```
  # echo "::memstat" | mdb -k
  ```

  Stats of VDEV prefetch - how many (metadata) sectors were used from low-level prefetch caches:

  ```
  # kstat -p zfs:0:vdev_cache_stats
  ```

Set dynamically:

  ```
  # echo zfs_prefetch_disable/W0t1 | mdb -kw
  ```

  Revert to default:

  ```
  # echo zfs_prefetch_disable/W0t0 | mdb -kw
  ```

Set the following parameter in the /etc/system file:

  ```
  set zfs:zfs_prefetch_disable = 1
  ```

Limiting ARC cache size (to 32GB in this case) in /etc/system file:

  ```
  set zfs:zfs_arc_max = 32212254720
  ```

Add device as ZIL/ZLOG, eg. c4t1d0, can be added as a ZFS log device:

  ```
  # zpool add pool1 log c4t1d0
  ```

If 2 F40 flash modules are available, you can add mirrored log devices:

  ```
  # zpool add pool1 log mirror c4t1d0 c4t2d0
  ```

Available F20 DOMs or F5100 FMODs can be added as a cache device for reads.

  ```
  # zpool add pool1 cache c4t3d0
  ```

You can't mirror cache devices, they will be striped together.

  ```
  # zpool add pool1 cache c4t3d0 c4t4d0
  ```

Check health of all poools:

  ```
  # zpool status -x
  ```
