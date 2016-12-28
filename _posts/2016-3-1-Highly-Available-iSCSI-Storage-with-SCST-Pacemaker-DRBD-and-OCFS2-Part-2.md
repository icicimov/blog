---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2 - Part2'
categories: 
  - High-Availability
tags: [iscsi, scst, pacemaker, drbd, ocfs2, high-availability]
date: 2016-3-2
series: "Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2"
---
{% include toc %}
This is continuation of the [Highly Available iSCSI Storage with SCST, Pacemaker, DRBD and OCFS2]({{ site.baseurl }}{% post_url 2016-3-1-Highly-Available-iSCSI-Storage-with-SCST-Pacemaker-DRBD-and-OCFS2 %}) series. We have setup the HA backing iSCSI storage and now we are going to setup a HA shared storage on the client side.

# iSCSI Client (Initiator) Servers Setup

What we have till now is a block device that we can access from our clients via iSCSI over IP network. However, iSCSI is stateful protocol but does not provide any state persistence on restart or state sharing between different sessions. Meaning the data written to the iSCSI device from one client is not visible to the other client connected to the same device via its own iSCSI session. That client needs to close its current session and re-connect to the target to be able to see the data written by the other client. Which in term means we need to provide additional layer on top of iSCSI target able to provide data replication in real time. This can be achieved with cluster aware file systems like GFS2 or OCFS2 for example which provide safe file locking.

We start by installing the client packages on both servers (drbd01 and drbd02) which are running Ubuntu-14.04 for OS:

```
# aptitude install -y open-iscsi open-iscsi-utils multipath-tools
```

First we are going to setup the Multipathing. This enables us to mitigate the effect of network card failure on the client side by providing two, or more, different network paths to the same target.Some illustration of this can be seen in the below pictures.

## iSCSI Client

Discover the targets and login to the LUN:

```
root@drbd01:~# iscsiadm -m discovery -t st -p 192.168.0.180
192.168.0.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
10.20.1.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
```

We login to both of them:

```
{% raw %}
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -p 192.168.0.180 --login
Logging in to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 192.168.0.180,3260] (multiple)
Login to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 192.168.0.180,3260] successful.

root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -p 10.20.1.180 --login
Logging in to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 10.20.1.180,3260] (multiple)
Login to [iface: default, target: iqn.2016-02.local.virtual:virtual.vg1, portal: 10.20.1.180,3260] successful.
{% endraw %}
root@drbd01:~# iscsiadm -m node -P 1
Target: iqn.2016-02.local.virtual:virtual.vg1
    Portal: 192.168.0.180:3260,1
        Iface Name: default
    Portal: 10.20.1.180:3260,1
        Iface Name: default
```

We can check the iSCSI sessions:

```
root@drbd01:~# iscsiadm -m session -P 1
Target: iqn.2016-02.local.virtual:virtual.vg1
    Current Portal: 192.168.0.180:3260,1
    Persistent Portal: 192.168.0.180:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:8d74927a5fe7
        Iface IPaddress: 192.168.0.176
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
    Current Portal: 10.20.1.180:3260,1
    Persistent Portal: 10.20.1.180:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:8d74927a5fe7
        Iface IPaddress: 10.20.1.16
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 2
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
```

and we can see a new block device has been created for each target we logged in (`/dev/sdc` and `/dev/sdd`):

```
root@drbd01:~# fdisk -l /dev/sdc
Disk /dev/sdc: 21.5 GB, 21470642176 bytes
64 heads, 32 sectors/track, 20476 cylinders, total 41934848 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 524288 bytes
Disk identifier: 0xda6e926c
Disk /dev/sdc doesn't contain a valid partition table
 
root@drbd01:~# fdisk -l /dev/sdd
Disk /dev/sdd: 21.5 GB, 21470642176 bytes
64 heads, 32 sectors/track, 20476 cylinders, total 41934848 sectors
Units = sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 524288 bytes
Disk identifier: 0xda6e926c
Disk /dev/sdd doesn't contain a valid partition table
 
root@drbd01:~# lsscsi
[1:0:0:0]    cd/dvd  QEMU     QEMU DVD-ROM     1.4.  /dev/sr0
[2:0:0:0]    disk    QEMU     QEMU HARDDISK    1.4.  /dev/sda
[2:0:1:0]    disk    QEMU     QEMU HARDDISK    1.4.  /dev/sdb
[3:0:0:0]    disk    SCST_FIO VDISK-LUN01       311  /dev/sdc
[4:0:0:0]    disk    SCST_FIO VDISK-LUN01       311  /dev/sdd
```

On the server side the sessions state can be seen as follows:

```
[root@centos01 ~]# scstadmin -list_sessions
 
Collecting current configuration: done.
 
Driver/Target: iscsi/iqn.2016-02.local.virtual:virtual.vg1
 
    Session: iqn.1993-08.org.debian:01:f0dda8483515
 
    Attribute                     Value                                       Writable      KEY
    -------------------------------------------------------------------------------------------
    DataDigest                    None                                        Yes           No
    FirstBurstLength              65536                                       Yes           No
    HeaderDigest                  None                                        Yes           No
    ImmediateData                 Yes                                         Yes           No
    InitialR2T                    No                                          Yes           No
    MaxBurstLength                1048576                                     Yes           No
    MaxOutstandingR2T             1                                           Yes           No
    MaxRecvDataSegmentLength      1048576                                     Yes           No
    MaxXmitDataSegmentLength      262144                                      Yes           No
    active_commands               0                                           Yes           No
    bidi_cmd_count                0                                           Yes           No
    bidi_io_count_kb              0                                           Yes           No
    bidi_unaligned_cmd_count      0                                           Yes           No
    commands                      0                                           Yes           No
    force_close                   <n/a>                                       Yes           No
    initiator_name                iqn.1993-08.org.debian:01:f0dda8483515      Yes           No
    none_cmd_count                1                                           Yes           No
    read_cmd_count                69466                                       Yes           No
    read_io_count_kb              8467233                                     Yes           No
    read_unaligned_cmd_count      2787                                        Yes           No
    reinstating                   0                                           Yes           No
    sid                           10000013d0200                               Yes           No
    thread_pid                    5003 5004 5005 5006 5007 5008 5009 5010     Yes           No
    unknown_cmd_count             0                                           Yes           No
    write_cmd_count               5201                                        Yes           No
    write_io_count_kb             759565                                      Yes           No
    write_unaligned_cmd_count     2122                                        Yes           No
 
    Session: iqn.1993-08.org.debian:01:f0dda8483515_1
 
    Attribute                     Value                                       Writable      KEY
    -------------------------------------------------------------------------------------------
    DataDigest                    None                                        Yes           No
    FirstBurstLength              65536                                       Yes           No
    HeaderDigest                  None                                        Yes           No
    ImmediateData                 Yes                                         Yes           No
    InitialR2T                    No                                          Yes           No
    MaxBurstLength                1048576                                     Yes           No
    MaxOutstandingR2T             1                                           Yes           No
    MaxRecvDataSegmentLength      1048576                                     Yes           No
    MaxXmitDataSegmentLength      262144                                      Yes           No
    active_commands               0                                           Yes           No
    bidi_cmd_count                0                                           Yes           No
    bidi_io_count_kb              0                                           Yes           No
    bidi_unaligned_cmd_count      0                                           Yes           No
    commands                      0                                           Yes           No
    force_close                   <n/a>                                       Yes           No
    initiator_name                iqn.1993-08.org.debian:01:f0dda8483515      Yes           No
    none_cmd_count                1                                           Yes           No
    read_cmd_count                68719                                       Yes           No
    read_io_count_kb              8434073                                     Yes           No
    read_unaligned_cmd_count      2543                                        Yes           No
    reinstating                   0                                           Yes           No
    sid                           40000023d0200                               Yes           No
    thread_pid                    5003 5004 5005 5006 5007 5008 5009 5010     Yes           No
    unknown_cmd_count             0                                           Yes           No
    write_cmd_count               5051                                        Yes           No
    write_io_count_kb             803872                                      Yes           No
    write_unaligned_cmd_count     1873                                        Yes           No
 
    Session: iqn.1993-08.org.debian:01:8d74927a5fe7
 
    Attribute                     Value                                       Writable      KEY
    -------------------------------------------------------------------------------------------
    DataDigest                    None                                        Yes           No
    FirstBurstLength              65536                                       Yes           No
    HeaderDigest                  None                                        Yes           No
    ImmediateData                 Yes                                         Yes           No
    InitialR2T                    No                                          Yes           No
    MaxBurstLength                1048576                                     Yes           No
    MaxOutstandingR2T             1                                           Yes           No
    MaxRecvDataSegmentLength      1048576                                     Yes           No
    MaxXmitDataSegmentLength      262144                                      Yes           No
    active_commands               0                                           Yes           No
    bidi_cmd_count                0                                           Yes           No
    bidi_io_count_kb              0                                           Yes           No
    bidi_unaligned_cmd_count      0                                           Yes           No
    commands                      0                                           Yes           No
    force_close                   <n/a>                                       Yes           No
    initiator_name                iqn.1993-08.org.debian:01:8d74927a5fe7      Yes           No
    none_cmd_count                1                                           Yes           No
    read_cmd_count                93712                                       Yes           No
    read_io_count_kb              12397667                                    Yes           No
    read_unaligned_cmd_count      2476                                        Yes           No
    reinstating                   0                                           Yes           No
    sid                           20000013d0200                               Yes           No
    thread_pid                    5003 5004 5005 5006 5007 5008 5009 5010     Yes           No
    unknown_cmd_count             0                                           Yes           No
    write_cmd_count               31189                                       Yes           No
    write_io_count_kb             10058311                                    Yes           No
    write_unaligned_cmd_count     1831                                        Yes           No
 
    Session: iqn.1993-08.org.debian:01:8d74927a5fe7_1
 
    Attribute                     Value                                       Writable      KEY
    -------------------------------------------------------------------------------------------
    DataDigest                    None                                        Yes           No
    FirstBurstLength              65536                                       Yes           No
    HeaderDigest                  None                                        Yes           No
    ImmediateData                 Yes                                         Yes           No
    InitialR2T                    No                                          Yes           No
    MaxBurstLength                1048576                                     Yes           No
    MaxOutstandingR2T             1                                           Yes           No
    MaxRecvDataSegmentLength      1048576                                     Yes           No
    MaxXmitDataSegmentLength      262144                                      Yes           No
    active_commands               0                                           Yes           No
    bidi_cmd_count                0                                           Yes           No
    bidi_io_count_kb              0                                           Yes           No
    bidi_unaligned_cmd_count      0                                           Yes           No
    commands                      0                                           Yes           No
    force_close                   <n/a>                                       Yes           No
    initiator_name                iqn.1993-08.org.debian:01:8d74927a5fe7      Yes           No
    none_cmd_count                1                                           Yes           No
    read_cmd_count                93665                                       Yes           No
    read_io_count_kb              12370128                                    Yes           No
    read_unaligned_cmd_count      2617                                        Yes           No
    reinstating                   0                                           Yes           No
    sid                           30000023d0200                               Yes           No
    thread_pid                    5003 5004 5005 5006 5007 5008 5009 5010     Yes           No
    unknown_cmd_count             0                                           Yes           No
    write_cmd_count               30986                                       Yes           No
    write_io_count_kb             10179922                                    Yes           No
    write_unaligned_cmd_count     1964                                        Yes           No
 
 
All done.

## Multipathing

Then we create the main Multipath configuration file `/etc/multipath.conf`:

```
defaults {
    user_friendly_names    yes
    # Use 'mpathn' names for multipath devices
 
    path_grouping_policy    multibus
    # Place all paths in one priority group
 
    path_checker    readsector0
    # Method to determine the state of a path
 
    polling_interval    3
    # How often (in seconds) to poll state of paths
 
    path_selector    "round-robin 0"
    # Algorithm to determine what path to use for next I/O operation
 
    failback    immediate
    # Failback to highest priority path group with active paths
 
    features    "0"
    no_path_retry    1
}
blacklist {
    wwid    0QEMU_QEMU_HARDDISK_drive-scsi0
    wwid    0QEMU_QEMU_HARDDISK_drive-scsi1
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^(hd|xvd|vd)[a-z]*"
    devnode "ofsctl"
    devnode "^asm/*"
}
multipaths {
  multipath {
    wwid    23238363932313833
    # alias here can be anything descriptive for your LUN
    alias    mylun
  }
}
```

We find the WWID (World Wide Identifier) of the disks as follows:

```
root@drbd01:~# /lib/udev/scsi_id --whitelisted --device=/dev/sda
0QEMU    QEMU HARDDISK   drive-scsi0
 
root@drbd01:~# /lib/udev/scsi_id --whitelisted --device=/dev/sdb
0QEMU    QEMU HARDDISK   drive-scsi1
 
root@drbd01:~# /lib/udev/scsi_id --whitelisted --device=/dev/sdc
23238363932313833
 
root@drbd01:~# /lib/udev/scsi_id --whitelisted --device=/dev/sdd
23238363932313833
```

The sda and sdb are our system disks the VM is running of thus we only want the iSCSI devices concidered by multiptah, which explains the above config. Now after restarting the multipathd daemon:

```
root@drbd01:~# service multipath-tools restart
```

we can see:

```
root@drbd01:~# multipath -v2
Feb 26 14:14:12 | sdc: rport id not found
Feb 26 14:14:12 | sdd: rport id not found
create: mylun (23238363932313833) undef SCST_FIO,VDISK-LUN01    
size=20G features='0' hwhandler='0' wp=undef
`-+- policy='round-robin 0' prio=1 status=undef
  |- 3:0:0:0 sdc 8:32 undef ready running
  `- 4:0:0:0 sdd 8:48 undef ready running
 
root@drbd01:~# multipath -ll
mylun (23238363932313833) dm-0 SCST_FIO,VDISK-LUN01    
size=20G features='1 queue_if_no_path' hwhandler='0' wp=rw
`-+- policy='round-robin 0' prio=1 status=active
  |- 3:0:0:0 sdc 8:32 active ready running
  `- 4:0:0:0 sdd 8:48 active ready running
```

The Multipath tool aslo created it's own mapper device:

```
root@drbd01:~# ls -l /dev/mapper/mylun
lrwxrwxrwx 1 root root 7 Feb 26 14:14 /dev/mapper/mylun -> ../dm-0
```

Now that we have the multipath setup we want to reduce the failover timeout which is 120sec by default:

```
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 120
node.session.timeo.replacement_timeout = 120
```

so we have faster failover upon failuer detetction:

```
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -o update -n node.session.timeo.replacement_timeout -v 10
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 10
node.session.timeo.replacement_timeout = 10
```

and also set the initiator to auto connect to the target on reboot:

```
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -o update -n node.startup -v automatic
```

### Testing path failover

To test we create a file system first on top of the multipath device and mount it:

```
root@drbd01:~# mkfs.ext4 /dev/mapper/mylun
root@drbd01:~# mkdir /share
root@drbd01:~# mount /dev/mapper/mylun /share -o _netdev
root@drbd01:~# cat /proc/mounts | grep mylun
/dev/mapper/mylun /share ext4 rw,relatime,stripe=128,data=ordered 0 0
```

Then we create the following test script `multipath_test.sh`:

```
#!/bin/bash
interval=1
while true; do
    ts=`date "+%Y.%m.%d-%H:%M:%S"`
    echo $ts > /share/file-${ts}
    echo "/share/file-${ts}...waiting $interval second(s)"
    sleep $interval
done 
```

that will keep creating files in the mount point in a loop. Now we start the script in one terminal and monitor the multipath state in another:

```
root@drbd01:~# multipath -ll
mylun (23238363932313833) dm-0 SCST_FIO,VDISK-LUN01    
size=20G features='1 queue_if_no_path' hwhandler='0' wp=rw
`-+- policy='round-robin 0' prio=1 status=active
  |- 3:0:0:0 sdc 8:32 active ready running
  `- 4:0:0:0 sdd 8:48 active ready running
```

We bring down one of the multipath interfaces:

```
root@drbd01:~# ifdown eth2
```

and check the status again:

```
root@drbd01:~# multipath -ll
mylun (23238363932313833) dm-0 SCST_FIO,VDISK-LUN01    
size=20G features='1 queue_if_no_path' hwhandler='0' wp=rw
`-+- policy='round-robin 0' prio=1 status=active
  |- 3:0:0:0 sdc 8:32 active ready  running
  `- 4:0:0:0 sdd 8:48 failed faulty running
```

We can see it is in failed state but that did not affect the script at all:

```
root@drbd01:~# bash multipath_test.sh
/share/file-2016.02.26-14:41:23...waiting 1 second(s)
/share/file-2016.02.26-14:41:24...waiting 1 second(s)
/share/file-2016.02.26-14:41:25...waiting 1 second(s)
/share/file-2016.02.26-14:41:26...waiting 1 second(s)
...
/share/file-2016.02.26-14:43:29...waiting 1 second(s)
/share/file-2016.02.26-14:43:30...waiting 1 second(s)
/share/file-2016.02.26-14:43:31...waiting 1 second(s)
/share/file-2016.02.26-14:43:32...waiting 1 second(s)
/share/file-2016.02.26-14:43:33...waiting 1 second(s)
^C
root@drbd01:~#
```

It kept running and created 130 files:

```
root@drbd01:~# ls -ltrh /share/file-2016.02.26-14* | wc -l
130
```

in the period of 130 seconds it was running. Now we bring back eth2:

```
root@drbd01:~# ifup eth2
 
root@drbd01:~# multipath -ll
mylun (23238363932313833) dm-0 SCST_FIO,VDISK-LUN01    
size=20G features='1 queue_if_no_path' hwhandler='0' wp=rw
`-+- policy='round-robin 0' prio=0 status=active
  |- 3:0:0:0 sdc 8:32 active ready running
  `- 4:0:0:0 sdd 8:48 active undef running
```

At the end, we can set the iscsi client and multipath to autostart in `/etc/iscsi/iscsid.conf`:

```
...
#node.startup = manual
node.startup = automatic
...
```

and update the run levels:

```
root@drbd01:~# update-rc.d -f open-iscsi remove
root@drbd01:~# update-rc.d open-iscsi start 20 2 3 4 5 . stop 20 0 1 6 .
root@drbd01:~# update-rc.d open-iscsi enable
```

For the target login:

```
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 -o update -n node.startup -v automatic
root@drbd01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:virtual.vg1 | grep node.startup
node.startup = automatic
node.startup = automatic
```

and then if we want auto mounting the file system we add it to `/etc/fstab` file:

```
...
/dev/mapper/mylun    /share    ext4    _netdev,noatime    0 0
```

Of course, in our case we are not going to do that since we'll have Pacemaker take care of this.

## Corosync and Pacemaker

Install the cluster stack packages on both servers (drbd01 and drbd02):

```
# aptitude install -y heartbeat pacemaker corosync fence-agents openais cluster-glue resource-agents openipmi ipmitool
```

First we generate Corosync authentication key. To insure we have enough entropy (since this is inside VM) we install haveged first, run corosync-keygen and then we copy the key over to the second server:

```
root@drbd02:~# aptitude install haveged
root@drbd02:~# service haveged start
root@drbd02:~# corosync-keygen -l
root@drbd02:~# scp /etc/corosync/authkey drbd02:/etc/corosync/authkey
```

Then we configure Corosync with 2 rings as per usual `/etc/corosync/corosync.conf`:

```
totem {
    version: 2
 
    # How long before declaring a token lost (ms)
    token: 3000
 
    # How many token retransmits before forming a new configuration
    token_retransmits_before_loss_const: 10
 
    # How long to wait for join messages in the membership protocol (ms)
    join: 60
 
    # How long to wait for consensus to be achieved before starting a new round of membership configuration (ms)
    consensus: 3600
 
    # Turn off the virtual synchrony filter
    vsftype: none
 
    # Number of messages that may be sent by one processor on receipt of the token
    max_messages: 20
 
    # Stagger sending the node join messages by 1..send_join ms
    send_join: 45
 
    # Limit generated nodeids to 31-bits (positive signed integers)
    clear_node_high_bit: yes
 
    # Disable encryption
    secauth: off
 
    # How many threads to use for encryption/decryption
    threads: 0
 
    # Optionally assign a fixed node id (integer)
    # nodeid: 1234
 
    # CLuster name, needed for DLM or DLM wouldn't start
    cluster_name: iscsi
 
    # This specifies the mode of redundant ring, which may be none, active, or passive.
    rrp_mode: active
 
    interface {
          ringnumber: 0
          bindnetaddr: 10.10.1.19
          mcastaddr: 226.94.1.1
          mcastport: 5404
    }
    interface {
            ringnumber: 1
            bindnetaddr: 192.168.0.177
            mcastaddr: 226.94.41.1
            mcastport: 5405
    }
    transport: udpu
}
nodelist {
    node {
        ring0_addr: 10.10.1.17
        ring1_addr: 192.168.0.176
        nodeid: 1
    }
    node {
        ring0_addr: 10.10.1.19
        ring1_addr: 192.168.0.177
        nodeid: 2
    }
}
quorum {
    provider: corosync_votequorum
    two_node: 1
}
amf {
    mode: disabled
}
service {
     # Load the Pacemaker Cluster Resource Manager
     # if 0: start pacemaker
     # if 1: don't start pacemaker
     ver:       1
     name:      pacemaker
}
aisexec {
        user:   root
        group:  root
}
logging {
        fileline: off
        to_stderr: yes
        to_logfile: no
        to_syslog: yes
    syslog_facility: daemon
        debug: off
        timestamp: on
        logger_subsys {
                subsys: subsys: QUORUM
                debug: off
                tags: enter|leave|trace1|trace2|trace3|trace4|trace6
        }
} 
```

Enable the service `/etc/default/corosync`:

```
# start corosync at boot [yes|no]
START=yes
```

and start it up:

```
root@drbd02:~# service corosync start
```

Make sure it starts on reboot:

```
root@drbd02:~# update-rc.d corosync defaults
 System start/stop links for /etc/init.d/corosync already exist.

root@drbd02:~# update-rc.d corosync enable
update-rc.d: warning:  start runlevel arguments (none) do not match corosync Default-Start values (2 3 4 5)
update-rc.d: warning:  stop runlevel arguments (none) do not match corosync Default-Stop values (0 1 6)
 Enabling system startup links for /etc/init.d/corosync ...
 Removing any system startup links for /etc/init.d/corosync ...
   /etc/rc0.d/K01corosync
   /etc/rc1.d/K01corosync
   /etc/rc2.d/S19corosync
   /etc/rc3.d/S19corosync
   /etc/rc4.d/S19corosync
   /etc/rc5.d/S19corosync
   /etc/rc6.d/K01corosync
 Adding system startup for /etc/init.d/corosync ...
   /etc/rc0.d/K01corosync -> ../init.d/corosync
   /etc/rc1.d/K01corosync -> ../init.d/corosync
   /etc/rc6.d/K01corosync -> ../init.d/corosync
   /etc/rc2.d/S19corosync -> ../init.d/corosync
   /etc/rc3.d/S19corosync -> ../init.d/corosync
   /etc/rc4.d/S19corosync -> ../init.d/corosync
   /etc/rc5.d/S19corosync -> ../init.d/corosync
```

Then we start pacemaker and check the status:

```
root@drbd02:~# service pacemaker start
 
root@drbd02:~# crm status
Last updated: Mon Feb 29 15:08:16 2016
Last change: Mon Feb 29 13:50:28 2016 via cibadmin on drbd01
Stack: corosync
Current DC: drbd01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
6 Resources configured
 
Online: [ drbd01 drbd02 ]
```

We make sure Pacemaker starts after open-iscsi and multiptah which are S20:

```
root@drbd02:~# update-rc.d -f pacemaker remove
root@drbd02:~# update-rc.d pacemaker start 50 1 2 3 4 5 . stop 01 0 6 .
root@drbd02:~# update-rc.d pacemaker enable
```

## OCFS2

Now, this part was really painful to setup due to complitelly broken OCFS2 cluster stack in Ubuntu-14.04. Install the needed packages on both nodes:

```
# aptitude install -y ocfs2-tools ocfs2-tools-pacemaker dlm
```

and we disable all these services from start-up since they are going to be under cluster control:

```
root@drbd02:~# update-rc.d dlm disable
root@drbd02:~# update-rc.d ocfs2 disable
root@drbd02:~# update-rc.d o2cb disable
```

For the DLM daemon `dlm_controld` to start we must have set the `cluster_name` parameter in totem for Corosync as shown above.

Unfortunatelly the DLM sysinit script has a bug too so we have to create a new one:

```
root@drbd02:~# mv /etc/init.d/dlm /etc/init.d/dlm.default
 
root@drbd02:~# vi /etc/init.d/dlm
#! /bin/sh
### BEGIN INIT INFO
# Provides:          dlm_controld
# Required-Start:    $network $remote_fs $time $syslog corosync
# Required-Stop:     $remote_fs $syslog
# Should-Start:
# Should-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Starts and stops dlm_controld
# Description:       Starts and stops dlm_controld
### END INIT INFO
 
# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="DLM Cluster Control Daemon"
NAME=dlm_controld
DAEMON=/usr/sbin/$NAME
DAEMON_ARGS=""
PIDFILE=/var/run/$NAME.pid
SCRIPTNAME=/etc/init.d/dlm
 
# Exit if the package is not installed
[ -x "$DAEMON" ] || exit 0
 
# Read configuration variable file if it is present
[ -r /etc/default/dlm ] && . /etc/default/dlm
 
# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh
 
# Define LSB log_* functions.
# Depend on lsb-base (>= 3.2-14) to ensure that this file is present
# and status_of_proc is working.
. /lib/lsb/init-functions
 
setup_dlm() {
    modprobe dlm > /dev/null 2>&1
    mount -t configfs none /sys/kernel/config > /dev/null 2>&1
}
 
#
# Function that starts the daemon/service
#
do_start()
{
    setup_dlm
 
    # Return
    #   0 if daemon has been started
    #   1 if daemon was already running
    #   2 if daemon could not be started
    start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON --test > /dev/null \
        || return 1
    start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON -- \
        $DAEMON_ARGS \
        || return 2
    # Add code here, if necessary, that waits for the process to be ready
    # to handle requests from services started subsequently which depend
    # on this one.  As a last resort, sleep for some time.
}
 
#
# Function that stops the daemon/service
#
do_stop()
{
    # Return
    #   0 if daemon has been stopped
    #   1 if daemon was already stopped
    #   2 if daemon could not be stopped
    #   other if a failure occurred
    start-stop-daemon --stop --quiet --retry=TERM/30/KILL/5 --pidfile $PIDFILE --name $NAME
    RETVAL="$?"
    [ "$RETVAL" = 2 ] && return 2
    # Wait for children to finish too if this is a daemon that forks
    # and if the daemon is only ever run from this initscript.
    # If the above conditions are not satisfied then add some other code
    # that waits for the process to drop all resources that could be
    # needed by services started subsequently.  A last resort is to
    # sleep for some time.
    start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec $DAEMON
    [ "$?" = 2 ] && return 2
    # Many daemons don't delete their pidfiles when they exit.
    rm -f $PIDFILE
    return "$RETVAL"
}
 
#
# Function that sends a SIGHUP to the daemon/service
#
do_reload() {
    #
    # If the daemon can reload its configuration without
    # restarting (for example, when it is sent a SIGHUP),
    # then implement that here.
    #
    start-stop-daemon --stop --signal 1 --quiet --pidfile $PIDFILE --name $NAME
    return 0
}
 
case "$1" in
  start)
    [ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
    do_start
    case "$?" in
        0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
        2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  stop)
    [ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
    do_stop
    case "$?" in
        0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
        2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  status)
    status_of_proc "$DAEMON" "$NAME" && exit 0 || exit $?
    ;;
  #reload|force-reload)
    #
    # If do_reload() is not implemented then leave this commented out
    # and leave 'force-reload' as an alias for 'restart'.
    #
    #log_daemon_msg "Reloading $DESC" "$NAME"
    #do_reload
    #log_end_msg $?
    #;;
  restart|force-reload)
    #
    # If the "reload" option is implemented then remove the
    # 'force-reload' alias
    #
    log_daemon_msg "Restarting $DESC" "$NAME"
    do_stop
    case "$?" in
      0|1)
        do_start
        case "$?" in
            0) log_end_msg 0 ;;
            1) log_end_msg 1 ;; # Old process is still running
            *) log_end_msg 1 ;; # Failed to start
        esac
        ;;
      *)
        # Failed to stop
        log_end_msg 1
        ;;
    esac
    ;;
  *)
    #echo "Usage: $SCRIPTNAME {start|stop|restart|reload|force-reload}" >&2
    echo "Usage: $SCRIPTNAME {start|stop|status|restart|force-reload}" >&2
    exit 3
    ;;
esac
 
:
```

Then we can finally create the DLM resource in Pacemaker and let it manage it:

```
# crm configure
primitive p_controld ocf:pacemaker:controld \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params daemon="dlm_controld" \
    meta target-role="Started"
commit
```

Next we create the O2CB cluster config in `/etc/ocfs2/cluster.conf`:

```
cluster:
    node_count = 2
    name = iscsi
 
node:
    ip_port = 7777
    ip_address = 10.10.1.17
    number = 0
    name = drbd01
    cluster = iscsi
  
node:
    ip_port = 7777
    ip_address = 10.10.1.19
    number = 1
    name = drbd02
    cluster = iscsi 
```

We can always change these parameters later, add new node etc. Enable the service similar like we did for DLM by editing the settings as shown below in `/etc/default/o2cb` file:

```
...
O2CB_ENABLED=true
O2CB_BOOTCLUSTER=iscsi
... 
```

Now we need to add the Pacemaker resources for the cluster management.The cluster stack for OCFS2 in Ubuntu-14.04 is broken. The usual resource definition in Pacemaker does not work:

```
primitive p_o2cb ocf:pacemaker:o2cb \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params stack="pcmk" daemon_timeout="10"
```

due to a bug in the O2CB OCF agent. Because of that we have to use the LSB startup script in Pacemaker like this:

```
primitive p_o2cb lsb:o2cb \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    meta target-role="Started"
```

The second bug is in the OCF file system agent where it only checks if the cluster type is "cman" thus in case of Ubuntu whit Corosync the agent fails. To fix the second bug, we edit `/usr/lib/ocf/resource.d/heartbeat/Filesystem` and find:

```
...
        if [ "X$HA_cluster_type" = "Xcman" ]; then
...
```

line and replace `cman` with `corosync`:

```
...
        if [ "X$HA_cluster_type" = "Xcorosync" ]; then
...
```

See the following bug reports for more details:
https://bugs.launchpad.net/ubuntu/+source/ocfs2-tools/+bug/1412438
https://bugs.launchpad.net/ubuntu/+source/ocfs2-tools/+bug/1412548

So, at the end we create the following resources:

```
primitive p_o2cb lsb:o2cb \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    meta target-role="Started"
primitive p_iscsi_fs ocf:heartbeat:Filesystem \
    params device="/dev/mapper/mylun" directory="/share" fstype="ocfs2" options="_netdev,noatime,rw,acl,user_xattr" \
    op monitor interval="20" timeout="40" \
    op start interval="0" timeout="60" \
    op stop interval="0" timeout="60" \
    meta target-role="Stopped"
commit
```

Notice that we create the OCFS2 file system resource as `Stopped` since we still haven't created the file system. We have to do it this way since the primitive needs to be under Pacemaker controll when the file system gets created but should not be running. Actually, since we are not using the Pacemaker OCF agent here this does not matter but just in case.

We now create the file system on the iSCSI multipath device we created before:

```
root@drbd01:~# mkfs.ocfs2 -b 4K -C 32K -N 4 -L ISCSI /dev/mapper/mylun
mkfs.ocfs2 1.6.4
Cluster stack: classic o2cb
Label: ISCSI
Features: sparse backup-super unwritten inline-data strict-journal-super xattr
Block size: 4096 (12 bits)
Cluster size: 32768 (15 bits)
Volume size: 21470642176 (655232 clusters) (5241856 blocks)
Cluster groups: 21 (tail covers 10112 clusters, rest cover 32256 clusters)
Extent allocator size: 8388608 (2 groups)
Journal size: 134217728
Node slots: 4
Creating bitmaps: done
Initializing superblock: done
Writing system files: done
Writing superblock: done
Writing backup superblock: 3 block(s)
Formatting Journals: done
Growing extent allocator: done
Formatting slot map: done
Formatting quota files: done
Writing lost+found: done
mkfs.ocfs2 successful
```

Finally we create `colocation`, `clone` and `order` resources so the services run on both nodes thus the final configuration looks like:

```
root@drbd02:~# crm configure show
node $id="1" drbd01
node $id="2" drbd02
primitive p_controld ocf:pacemaker:controld \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100" \
    params daemon="dlm_controld"
primitive p_fs_ocfs2 ocf:heartbeat:Filesystem \
    params device="/dev/mapper/mylun" directory="/share" fstype="ocfs2" options="_netdev,noatime,rw,acl,user_xattr" \
    op monitor interval="20" timeout="40" \
    op start interval="0" timeout="60" \
    op stop interval="0" timeout="60" \
    meta is-managed="true"
primitive p_o2cb lsb:o2cb \
    op monitor interval="60" timeout="60" \
    op start interval="0" timeout="90" \
    op stop interval="0" timeout="100"
clone cl_dlm p_controld \
    meta globally-unique="false" interleave="true"
clone cl_fs_ocfs2 p_fs_ocfs2 \
    meta globally-unique="false" interleave="true" ordered="true"
clone cl_o2cb p_o2cb \
    meta globally-unique="false" interleave="true"
colocation cl_fs_o2cb inf: cl_fs_ocfs2 cl_o2cb
colocation cl_o2cb_dlm inf: cl_o2cb cl_dlm
order o_dlm_o2cb inf: cl_dlm:start cl_o2cb:start
order o_o2cb_ocfs2 inf: cl_o2cb cl_fs_ocfs2
property $id="cib-bootstrap-options" \
    dc-version="1.1.10-42f2063" \
    cluster-infrastructure="corosync" \
    stonith-enabled="false" \
    no-quorum-policy="ignore" \
    last-lrm-refresh="1456740232"
```

and `crm status` shows all is up and running on both nodes:

```
root@drbd01:~# crm status
Last updated: Mon Feb 29 21:44:50 2016
Last change: Mon Feb 29 21:41:53 2016 via crmd on drbd01
Stack: corosync
Current DC: drbd01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
6 Resources configured
 
Online: [ drbd01 drbd02 ]
 
 Clone Set: cl_dlm [p_controld]
     Started: [ drbd01 drbd02 ]
 Clone Set: cl_o2cb [p_o2cb]
     Started: [ drbd01 drbd02 ]
 Clone Set: cl_fs_ocfs2 [p_fs_ocfs2]
     Started: [ drbd01 drbd02 ]
```

and see the mount point on both nodes:

```
root@drbd02:~# cat /proc/mounts | grep share
/dev/mapper/mylun /share ocfs2 rw,noatime,_netdev,heartbeat=local,nointr,data=ordered,errors=remount-ro,atime_quantum=60,coherency=full,user_xattr,acl 0 0
```

We can further check the OCFS2 services state as well:

```
root@drbd01:~# service o2cb status
Driver for "configfs": Loaded
Filesystem "configfs": Mounted
Stack glue driver: Loaded
Stack plugin "o2cb": Loaded
Driver for "ocfs2_dlmfs": Loaded
Filesystem "ocfs2_dlmfs": Mounted
Checking O2CB cluster iscsi: Online
Heartbeat dead threshold = 31
  Network idle timeout: 30000
  Network keepalive delay: 2000
  Network reconnect delay: 2000
Checking O2CB heartbeat: Active
 
root@drbd01:~# service ocfs2 status
Active OCFS2 mountpoints:  /share
 
root@drbd01:~# mounted.ocfs2 -f
Device                FS     Nodes
/dev/sdc              ocfs2  drbd01, drbd02
/dev/mapper/mylun     ocfs2  drbd01, drbd02
/dev/sdd              ocfs2  drbd01, drbd02
```

In case of errors in crm we can cleanup the resources:

```
# crm_resource -r all --cleanup
```

or restart pacemaker service if needed.

We can now test the clusterred file system by creating a test file on one of the nodes and checking if we can see it on the other node:

```
root@drbd02:~# echo rteergreg > /share/test
 
root@drbd01:~# ls -l /share/
total 0
drwxr-xr-x 2 root root 3896 Feb 29 12:37 lost+found
-rw-r--r-- 1 root root   10 Feb 29 13:06 test
```

So we created file on one node and can see the same on the second one.

## Fail-over Testing

I did some testing to check what happens on the clients when the backend storage fails over. I modified the test script `fail_test.sh` slightly to write the current time stamp in a file on the share:

```
#!/bin/bash
interval=1
while true; do
    ts=`date "+%Y.%m.%d-%H:%M:%S"`
    echo $ts >> /share/file-${HOSTNAME}.log
    echo "/share/file-${ts}...waiting $interval second(s)"
    sleep $interval
done
```

and ran it on both clients drbd01 and drbd02. Then while the script was writing to a file on the share I rebooted the storage master:

```
[root@centos01 ~]# crm status
Last updated: Wed Mar  2 11:46:03 2016
Last change: Wed Mar  2 11:42:12 2016
Stack: classic openais (with plugin)
Current DC: centos02 - partition with quorum
Version: 1.1.11-97629de
2 Nodes configured, 2 expected votes
12 Resources configured
 
Online: [ centos01 centos02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd_vg1 [p_drbd_vg1]
     Masters: [ centos02 ]
     Slaves: [ centos01 ]
 Resource Group: g_vg1
     p_lvm_vg1    (ocf::heartbeat:LVM):    Started centos02
     p_target_vg1    (ocf::scst:SCSTTarget):    Started centos02
     p_lu_vg1_lun1    (ocf::scst:SCSTLun):    Started centos02
     p_ip_vg1    (ocf::heartbeat:IPaddr2):    Started centos02
     p_ip_vg1_2    (ocf::heartbeat:IPaddr2):    Started centos02
     p_portblock_vg1    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_unblock    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_2    (ocf::heartbeat:portblock):    Started centos02
     p_portblock_vg1_2_unblock    (ocf::heartbeat:portblock):    Started centos02
     p_email_admin    (ocf::heartbeat:MailTo):    Started centos02
```

reboot centos02 server:

```
[root@centos02 ~]# reboot
```

and could see the cluster detecting the failure and moving the resources to the still running centos01 node:

```
[root@centos01 ~]# crm status
Last updated: Wed Mar  2 11:46:15 2016
Last change: Wed Mar  2 11:42:12 2016
Stack: classic openais (with plugin)
Current DC: centos02 - partition with quorum
Version: 1.1.11-97629de
2 Nodes configured, 2 expected votes
12 Resources configured
 
Online: [ centos01 centos02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd_vg1 [p_drbd_vg1]
     Masters: [ centos02 ]
     Slaves: [ centos01 ]
 Resource Group: g_vg1
     p_lvm_vg1    (ocf::heartbeat:LVM):    Started centos02
     p_target_vg1    (ocf::scst:SCSTTarget):    Started centos02
     p_lu_vg1_lun1    (ocf::scst:SCSTLun):    Stopped
     p_ip_vg1    (ocf::heartbeat:IPaddr2):    Stopped
     p_ip_vg1_2    (ocf::heartbeat:IPaddr2):    Stopped
     p_portblock_vg1    (ocf::heartbeat:portblock):    Stopped
     p_portblock_vg1_unblock    (ocf::heartbeat:portblock):    Stopped
     p_portblock_vg1_2    (ocf::heartbeat:portblock):    Stopped
     p_portblock_vg1_2_unblock    (ocf::heartbeat:portblock):    Stopped
     p_email_admin    (ocf::heartbeat:MailTo):    Stopped 
```

and after short time:

``` 
[root@centos01 ~]# crm status
Last updated: Wed Mar  2 11:46:40 2016
Last change: Wed Mar  2 11:46:18 2016
Stack: classic openais (with plugin)
Current DC: centos01 - partition WITHOUT quorum
Version: 1.1.11-97629de
2 Nodes configured, 2 expected votes
12 Resources configured
 
Online: [ centos01 ]
OFFLINE: [ centos02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd_vg1 [p_drbd_vg1]
     Masters: [ centos01 ]
     Stopped: [ centos02 ]
 Resource Group: g_vg1
     p_lvm_vg1    (ocf::heartbeat:LVM):    Started centos01
     p_target_vg1    (ocf::scst:SCSTTarget):    Started centos01
     p_lu_vg1_lun1    (ocf::scst:SCSTLun):    Started centos01
     p_ip_vg1    (ocf::heartbeat:IPaddr2):    Started centos01
     p_ip_vg1_2    (ocf::heartbeat:IPaddr2):    Started centos01
     p_portblock_vg1    (ocf::heartbeat:portblock):    Started centos01
     p_portblock_vg1_unblock    (ocf::heartbeat:portblock):    Started centos01
     p_portblock_vg1_2    (ocf::heartbeat:portblock):    Started centos01
     p_portblock_vg1_2_unblock    (ocf::heartbeat:portblock):    Started centos01
     p_email_admin    (ocf::heartbeat:MailTo):    Started centos01
```

so the whole transition took around 6 seconds. I checked the clients files then and could see the same, the I/O was suspended for 6 seconds and after that the script went on writing to the file it had opened:

```
root@drbd01:~# more /share/file-drbd01.log
2016.03.02-11:45:44
2016.03.02-11:45:45
2016.03.02-11:45:46
.
.
.
2016.03.02-11:46:01
2016.03.02-11:46:02
2016.03.02-11:46:03
2016.03.02-11:46:09
2016.03.02-11:46:10
2016.03.02-11:46:11
2016.03.02-11:46:12
```

## Load Testing

Just some simple `dd` tests with clear system and disk cache to get idea about the storage speed and limitations.

```
root@drbd01:~# echo 3 > /proc/sys/vm/drop_caches
root@drbd01:~# dd if=/dev/zero of=/share/test.img bs=1024K count=1500 oflag=direct conv=fsync && sync;sync
1500+0 records in
1500+0 records out
1572864000 bytes (1.6 GB) copied, 80.8872 s, 19.4 MB/s
 
root@drbd01:~# echo 3 > /proc/sys/vm/drop_caches
root@drbd01:~# time cat /share/test.img > /dev/null
real    0m36.464s
user    0m0.023s
sys    0m1.762s
 
root@drbd01:~# echo 3 > /proc/sys/vm/drop_caches
root@drbd01:~# dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
3072000+0 records in
3072000+0 records out
1572864000 bytes (1.6 GB) copied, 33.1996 s, 47.4 MB/s
```

Then, trying to simulate real live workload, I started 10 simultaneous processes on both servers:

```
root@drbd01:~# for i in $(seq 1 10); do { dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync &}; done
root@drbd02:~# for i in $(seq 1 10); do { dd if=/share/test2.img of=/dev/null iflag=nocache oflag=nocache,sync &}; done
```

reading one of the big files. When finished the processes reported throughput of 7.4MB/s in this case.

```
[1]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[2]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[3]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[4]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[5]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[6]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[7]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[8]   Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[9]-  Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
[10]+  Done                    dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
 
3072000+0 records out
1572864000 bytes (1.6 GB) copied, 212.11 s, 7.4 MB/s
3072000+0 records in
3072000+0 records out
```

Have in mind though that the whole stack is running on 4 nested VM's when taking the results in account.

{% include series.html %}