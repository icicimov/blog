---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Highly Available iSCSI ALUA (Asymetric Logical Unit Access) Storage with Pacemaker and DRBD in Dual-Primary mode - Part2'
categories: 
  - High-Availability
tags: [iscsi, scst, pacemaker, drbd, high-availability]
date: 2016-3-13
series: "Highly Available iSCSI ALUA Storage with Pacemaker and DRBD in Dual-Primary mode"
---
{% include toc %}
This is continuation of the [Highly Available iSCSI ALUA Storage with Pacemaker and DRBD in Dual-Primary mode]({{ site.baseurl }}{% post_url 2016-3-9-Highly-Available-iSCSI-ALUA-Storage-with-Pacemaker-and-DRBD-in-Dual-Primary-mode %}) series. We have setup the HA backing iSCSI storage and now we are going to setup a HA shared storage on the client side.

# iSCSI Client (Initiator) Servers Setup

As mentioned before these servers are running the latest Debian Jessie release:

```
root@proxmox01:~# lsb_release -a
No LSB modules are available.
Distributor ID:    Debian
Description:    Debian GNU/Linux 8.3 (jessie)
Release:    8.3
Codename:    jessie
```

Same as in our previous setup we will use Multipathing for our Targets. Our client servers are proxmox01 and proxmox02 with following network config:

```
root@proxmox01:~# ifconfig
eth0      Link encap:Ethernet  HWaddr 52:54:00:70:2a:f7 
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1246893 errors:0 dropped:0 overruns:0 frame:0
          TX packets:119352 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:222250289 (211.9 MiB)  TX bytes:25971272 (24.7 MiB)
 
eth1      Link encap:Ethernet  HWaddr 52:54:00:5d:8f:fc 
          inet addr:192.168.152.52  Bcast:192.168.152.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fe5d:8ffc/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:962 errors:0 dropped:0 overruns:0 frame:0
          TX packets:208 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:386042 (376.9 KiB)  TX bytes:17556 (17.1 KiB)
 
vmbr0     Link encap:Ethernet  HWaddr 52:54:00:70:2a:f7 
          inet addr:192.168.122.160  Bcast:192.168.122.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fe70:2af7/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1246848 errors:0 dropped:0 overruns:0 frame:0
          TX packets:119353 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:204787619 (195.3 MiB)  TX bytes:25971378 (24.7 MiB)
 
root@proxmox02:~# ifconfig
eth0      Link encap:Ethernet  HWaddr 52:54:00:51:6e:74 
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1190402 errors:0 dropped:0 overruns:0 frame:0
          TX packets:1567653 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:516871378 (492.9 MiB)  TX bytes:610374910 (582.0 MiB)
 
eth1      Link encap:Ethernet  HWaddr 52:54:00:f7:df:df 
          inet addr:192.168.152.62  Bcast:192.168.152.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fef7:dfdf/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:160786 errors:0 dropped:0 overruns:0 frame:0
          TX packets:1214 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:1000
          RX bytes:11285786 (10.7 MiB)  TX bytes:106168 (103.6 KiB)
 
vmbr0     Link encap:Ethernet  HWaddr 52:54:00:51:6e:74 
          inet addr:192.168.122.170  Bcast:192.168.122.255  Mask:255.255.255.0
          inet6 addr: fe80::5054:ff:fe51:6e74/64 Scope:Link
          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
          RX packets:1190387 errors:0 dropped:0 overruns:0 frame:0
          TX packets:1567654 errors:0 dropped:0 overruns:0 carrier:0
          collisions:0 txqueuelen:0
          RX bytes:500204984 (477.0 MiB)  TX bytes:610375016 (582.0 MiB)
```

Install the needed software:

```
root@proxmox01:~# aptitude install sg3-utils lsscsi open-iscsi
```

We do the next steps on both nodes although I show the process on the proxmox01 only. Discover the targets:

```
root@proxmox01:~# iscsiadm -m discovery -t st -p 192.168.122.98
192.168.122.98:3260,1 iqn.2016-02.local.virtual:hpms02.vg1
192.168.152.98:3260,1 iqn.2016-02.local.virtual:hpms02.vg1
 
root@proxmox01:~# iscsiadm -m discovery -t st -p 192.168.122.99
192.168.122.99:3260,1 iqn.2016-02.local.virtual:hpms01.vg1
192.168.152.99:3260,1 iqn.2016-02.local.virtual:hpms01.vg1
```

and login:

```
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 -p 192.168.122.99:3260 --login
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 -p 192.168.152.99:3260 --login
 
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 -p 192.168.122.98:3260 --login
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 -p 192.168.152.98:3260 --login
```

Check the sessions:

```
root@proxmox01:~# iscsiadm -m session -P 1
Target: iqn.2016-02.local.virtual:hpms01.vg1 (non-flash)
    Current Portal: 192.168.122.99:3260,1
    Persistent Portal: 192.168.122.99:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
    Current Portal: 192.168.152.99:3260,1
    Persistent Portal: 192.168.152.99:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 7
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
Target: iqn.2016-02.local.virtual:hpms02.vg1 (non-flash)
    Current Portal: 192.168.122.98:3260,1
    Persistent Portal: 192.168.122.98:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 2
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
    Current Portal: 192.168.152.98:3260,1
    Persistent Portal: 192.168.152.98:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 8
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
```

To find which device belongs to which portal connection we can run the same command with "-P 3" to get even more details:

```
root@proxmox01:~# iscsiadm -m session -P3
iSCSI Transport Class version 2.0-870
version 2.0-873
Target: iqn.2016-02.local.virtual:hpms01.vg1 (non-flash)
    Current Portal: 192.168.122.99:3260,1
    Persistent Portal: 192.168.122.99:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 17
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        *********
        Timeouts:
        *********
        Recovery Timeout: 120
        Target Reset Timeout: 30
        LUN Reset Timeout: 30
        Abort Timeout: 15
        *****
        CHAP:
        *****
        username: <empty>
        password: ********
        username_in: <empty>
        password_in: ********
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        MaxXmitDataSegmentLength: 1048576
        FirstBurstLength: 65536
        MaxBurstLength: 1048576
        ImmediateData: Yes
        InitialR2T: No
        MaxOutstandingR2T: 1
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 18    State: running
        scsi18 Channel 00 Id 0 Lun: 0
            Attached scsi disk sda        State: running
    Current Portal: 192.168.152.99:3260,1
    Persistent Portal: 192.168.152.99:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.152.52
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 18
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        *********
        Timeouts:
        *********
        Recovery Timeout: 120
        Target Reset Timeout: 30
        LUN Reset Timeout: 30
        Abort Timeout: 15
        *****
        CHAP:
        *****
        username: <empty>
        password: ********
        username_in: <empty>
        password_in: ********
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        MaxXmitDataSegmentLength: 1048576
        FirstBurstLength: 65536
        MaxBurstLength: 1048576
        ImmediateData: Yes
        InitialR2T: No
        MaxOutstandingR2T: 1
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 19    State: running
        scsi19 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdb        State: running
Target: iqn.2016-02.local.virtual:hpms02.vg1 (non-flash)
    Current Portal: 192.168.122.98:3260,1
    Persistent Portal: 192.168.122.98:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.122.160
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 19
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        *********
        Timeouts:
        *********
        Recovery Timeout: 120
        Target Reset Timeout: 30
        LUN Reset Timeout: 30
        Abort Timeout: 15
        *****
        CHAP:
        *****
        username: <empty>
        password: ********
        username_in: <empty>
        password_in: ********
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        MaxXmitDataSegmentLength: 1048576
        FirstBurstLength: 65536
        MaxBurstLength: 1048576
        ImmediateData: Yes
        InitialR2T: No
        MaxOutstandingR2T: 1
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 20    State: running
        scsi20 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdc        State: running
    Current Portal: 192.168.152.98:3260,1
    Persistent Portal: 192.168.152.98:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:f1da7239b69
        Iface IPaddress: 192.168.152.52
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 20
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
        *********
        Timeouts:
        *********
        Recovery Timeout: 120
        Target Reset Timeout: 30
        LUN Reset Timeout: 30
        Abort Timeout: 15
        *****
        CHAP:
        *****
        username: <empty>
        password: ********
        username_in: <empty>
        password_in: ********
        ************************
        Negotiated iSCSI params:
        ************************
        HeaderDigest: None
        DataDigest: None
        MaxRecvDataSegmentLength: 262144
        MaxXmitDataSegmentLength: 1048576
        FirstBurstLength: 65536
        MaxBurstLength: 1048576
        ImmediateData: Yes
        InitialR2T: No
        MaxOutstandingR2T: 1
        ************************
        Attached SCSI devices:
        ************************
        Host Number: 21    State: running
        scsi21 Channel 00 Id 0 Lun: 0
            Attached scsi disk sdd        State: running
```

We can see the 4 new block devices have been created upon loging to the targets, `sda`, `sdb`, `sdc` and `sdd`. The device names depened on the loging order so it is important we use disk-by-id or the disk WWID in our further configuration as the disk order/names can change. Tthe LUN's from hpms01 have been mounted localy as `sda` and `sdb`, whereis the LUN's from hpms02 as `sdc` and `sdd`. These disks have to match the multipath connections further down on this page and groupped in appropriate paths of which the path leading to the current SCST ALUA Master (and its disks) should be marked as `status=active` and other one as `status=enabled`.

We can query one of the devices to discover the features offered by the iSCSI backend:

```
root@proxmox01:~# sg_inq /dev/sda
standard INQUIRY:
  PQual=0  Device_type=0  RMB=0  LU_CONG=0  version=0x06  [SPC-4]
  [AERC=0]  [TrmTsk=0]  NormACA=0  HiSUP=0  Resp_data_format=2
  SCCS=0  ACC=0  TPGS=1  3PC=1  Protect=0  [BQue=0]
  EncServ=0  MultiP=1 (VS=0)  [MChngr=0]  [ACKREQQ=0]  Addr16=0
  [RelAdr=0]  WBus16=0  Sync=0  [Linked=0]  [TranDis=0]  CmdQue=1
  [SPI: Clocking=0x0  QAS=0  IUS=0]
    length=66 (0x42)   Peripheral device type: disk
 Vendor identification: SCST_BIO
 Product identification: vg1            
 Product revision level:  320
 Unit serial number: 509f7d73
```

where most important value is `TPGS=1` which tells us the path groups are enabled on the target. Now to read the TPG settings:

```
root@proxmox01:~# sg_rtpg -vvd /dev/sda
open /dev/sda with flags=0x802
    report target port groups cdb: a3 0a 00 00 00 00 00 00 04 00 00 00
    report target port group: pass-through requested 1024 bytes (data-in) but got 28 bytes
Report list length = 28
Report target port groups:
  target port group id : 0x1 , Pref=0, Rtpg_fmt=0
    target port group asymmetric access state : 0x00 (active/optimized)
    T_SUP : 1, O_SUP : 1, LBD_SUP : 0, U_SUP : 1, S_SUP : 1, AN_SUP : 1, AO_SUP : 1
    status code : 0x02 (target port asym. state changed by implicit lu behaviour)
    vendor unique status : 0x00
    target port count : 01
    Relative target port ids:
      0x01
  target port group id : 0x2 , Pref=0, Rtpg_fmt=0
    target port group asymmetric access state : 0x01 (active/non optimized)
    T_SUP : 1, O_SUP : 1, LBD_SUP : 0, U_SUP : 1, S_SUP : 1, AN_SUP : 1, AO_SUP : 1
    status code : 0x02 (target port asym. state changed by implicit lu behaviour)
    vendor unique status : 0x00
    target port count : 01
    Relative target port ids:
      0x02
```

where we can see both TPGS (Target Port Group) we created on the server, marked with id of 1 and 2. It also tells us that the target has implicit ALUA feature. We can also see that the TPG id 1 is in `active/optimized` state and id 2 in `active/non optimized`, exactly as we want them to be and the way we configured them on the server.

To learn more about the device we can run:

```
root@proxmox01:~# sg_vpd -p 0x83 --hex /dev/sda
Device Identification VPD page:
 00     00 83 00 34 02 01 00 14  53 43 53 54 5f 42 49 4f    ...4....SCST_BIO
 10     35 30 39 66 37 64 37 33  2d 76 67 31 01 14 00 04    509f7d73-vg1....
 20     00 00 00 01 01 15 00 04  00 00 00 01 01 02 00 08    ................
 30     35 30 39 66 37 64 37 33                             509f7d73
```

which gives us some details about the device PVD (Virtual Product Data) in case they are not clear enough in the previous outputs.

All other devices will show the same output since all of them are mapped to the same LUN in the iSCSI server. Now armed with this knowledge we can install and configure Multipath. First find the WWID of the new device:

```
root@proxmox01:~# /lib/udev/scsi_id -g -u -d /dev/sda
23530396637643733
```

and then we create Multipath config file. This is the config that worked wor me `/etc/multipath.conf`:

```
defaults {
    user_friendly_names         yes
    polling_interval            2
    path_selector               "round-robin 0"
    path_grouping_policy        group_by_prio
    path_checker                readsector0
    #getuid_callout             "/lib/udev/scsi_id -g -u -d /dev/%n"
    rr_min_io                   100
    failback                    immediate
    prio                        "alua"
    features                    "0"
    no_path_retry               1
    detect_prio                 yes
    retain_attached_hw_handler  yes
}
 
devices {
  device {
    vendor              "SCST_BIO"
    product             "vg1"
    hardware_handler    "1 alua"
  }
}
 
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^(hd|xvd|vd)[a-z]*"
    devnode "ofsctl"
    devnode "^asm/*"
}
 
blacklist_exceptions {
        wwid "23238363932313833"
        property "(ID_SCSI_VPD|ID_WWN|ID_SERIAL)"
}
 
multipaths {
  multipath {
    wwid    23238363932313833
    alias    mylun
  }
}
```

The way we set it up means Multipath will use both links in the active path in `round-robin` fashion sending minimum of 100 I/Os down one link before it switches to the other one. In this way we are trying to avoid or minimize any issues in case one of the links in the active path suffers from congestion.

Restart the service:

```
root@proxmox01:~# systemctl restart multipath-tools.service
```

and check multipath:

```
root@proxmox01:~# multipath -ll
mpatha (23530396637643733) dm-3 SCST_BIO,vg1
size=20G features='2 queue_if_no_path retain_attached_hw_handler' hwhandler='1 alua' wp=rw
|-+- policy='round-robin 0' prio=50 status=active
| |- 2:0:0:0 sda 8:0  active ready running
| `- 8:0:0:0 sdc 8:32 active ready running
`-+- policy='round-robin 0' prio=10 status=enabled
  |- 3:0:0:0 sdb 8:16 active ready running
  `- 9:0:0:0 sdd 8:48 active ready running
```

We can see Multipath created 2 multipaths for each iSCSI server and marked the first one as `Primary` with priority of 50 and status of active, and the second one as `Secondary` with priority of 10 and status of enabled. It also created our new multipath device:

```
root@proxmox01:~# ls -l /dev/mapper/mpatha
lrwxrwxrwx 1 root root 7 Mar  9 12:54 /dev/mapper/mpatha -> ../dm-3
```

which we can mount and start using as any other block device.

Whats left is set the path failure timeout to 10 seconds from the default 120 seconds which is too high:

```
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 120
node.session.timeo.replacement_timeout = 120
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 -o update -n node.session.timeo.replacement_timeout -v 10
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 10
node.session.timeo.replacement_timeout = 10

root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 120
node.session.timeo.replacement_timeout = 120
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 -o update -n node.session.timeo.replacement_timeout -v 10
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 | grep node.session.timeo.replacement_timeout
node.session.timeo.replacement_timeout = 10
node.session.timeo.replacement_timeout = 10
```

and set client to login to the targets on startup:

```
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms01.vg1 -o update -n node.startup -v automatic
root@proxmox01:~# iscsiadm -m node -T iqn.2016-02.local.virtual:hpms02.vg1 -o update -n node.startup -v automatic
```

so the device is available to Multipath. Finally we set Multipath to auto start:

```
root@proxmox01:~# systemctl enable multipath-tools
Synchronizing state for multipath-tools.service with sysvinit using update-rc.d...
Executing /usr/sbin/update-rc.d multipath-tools defaults
Executing /usr/sbin/update-rc.d multipath-tools enable
```

# TESTING

## Multipath and Cluster failover

First, basic Multipath test with link failure detection. We bring down `eth1` which is one of the links in the active path:

```
root@proxmox01:~# ifdown eth1
root@proxmox01:~# multipath -ll
mpatha (23530396637643733) dm-3 SCST_BIO,vg1
size=20G features='2 queue_if_no_path retain_attached_hw_handler' hwhandler='1 alua' wp=rw
|-+- policy='round-robin 0' prio=50 status=active
| |- 2:0:0:0 sda 8:0  active ready  running
| `- 8:0:0:0 sdc 8:32 active faulty running
`-+- policy='round-robin 0' prio=10 status=enabled
  |- 3:0:0:0 sdb 8:16 active ready  running
  `- 9:0:0:0 sdd 8:48 active ready  running
```

and we can see Multipath noticed that and marked it as faulty. On bringing it back:

```
root@proxmox01:~# ifup eth1
root@proxmox01:~# multipath -ll
mpatha (23530396637643733) dm-3 SCST_BIO,vg1
size=20G features='2 queue_if_no_path retain_attached_hw_handler' hwhandler='1 alua' wp=rw
|-+- policy='round-robin 0' prio=50 status=active
| |- 8:0:0:0 sdc 8:32 active ready running
| `- 2:0:0:0 sda 8:0  active ready running
`-+- policy='round-robin 0' prio=10 status=enabled
  |- 3:0:0:0 sdb 8:16 active ready running
  `- 9:0:0:0 sdd 8:48 active ready running
```

it puts it back into the active state.

Next we test the failover of the iSCSI backend servers. Take a note of the Multipath state above and the cluster resources state:

```
root@hpms01:~# crm status
Last updated: Thu Mar 17 00:56:50 2016
Last change: Thu Mar 17 00:47:41 2016 via cibadmin on hpms01
Stack: corosync
Current DC: hpms01 (1) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured
 
Online: [ hpms01 hpms02 ]
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms01 hpms02 ]
 Master/Slave Set: ms_scst [p_scst]
     Masters: [ hpms01 ]
     Slaves: [ hpms02 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms01 hpms02 ]
```

Now reboot the hpms01 node which has the iSCSI target active (Master mode of ms_scst resource):

```
root@hpms01:~# reboot
Broadcast message from ubuntu@hpms01
    (/dev/pts/0) at 1:01 ...

The system is going down for reboot NOW!
```

and monitor pacemaker state on the second node, hpms02:

```
root@hpms02:~# crm_mon -Qrf
Stack: corosync
Current DC: hpms02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured
 
Online: [ hpms02 ]
Offline: [ hpms01 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms02 ]
     Stopped: [ hpms01 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms02 ]
     Stopped: [ hpms01 ]
 Master/Slave Set: ms_scst [p_scst]
     Masters: [ hpms02 ]
     Stopped: [ hpms01 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms02 ]
     Stopped: [ hpms01 ]
 
Migration summary:
* Node hpms02:
* Node hpms01:
```

We can see the cluster detected the node hpms01 went offline and promoted the ms_scst resource on the other node into Master state.

On the client, we can also see Multipath switched to the secondary path and marked the primary one as faulty:

```
root@proxmox01:~# multipath -ll
mpatha (23530396637643733) dm-3 SCST_BIO,vg1
size=20G features='2 queue_if_no_path retain_attached_hw_handler' hwhandler='1 alua' wp=rw
`-+- policy='round-robin 0' prio=50 status=active
  |- 6:0:0:0 sda 8:0  failed faulty offline
  |- 7:0:0:0 sdd 8:48 failed faulty offline
  |- 8:0:0:0 sdc 8:32 active ready  running
  `- 9:0:0:0 sdb 8:16 active ready  running
```

and the shared drive is still mounted and the file system available:

```
root@proxmox01:~# ls -l  /share/
total 1536000
-rw-r--r-- 1 root root 1572864000 Mar 11 11:36 test.img
```

When hpms01 comes online:

```
root@hpms02:~# crm_mon -Qrf1
Stack: corosync
Current DC: hpms02 (2) - partition with quorum
Version: 1.1.10-42f2063
2 Nodes configured
10 Resources configured
 
Online: [ hpms01 hpms02 ]
 
Full list of resources:
 
 Master/Slave Set: ms_drbd [p_drbd_vg1]
     Masters: [ hpms01 hpms02 ]
 Clone Set: cl_lvm [p_lvm_vg1]
     Started: [ hpms01 hpms02 ]
 Master/Slave Set: ms_scst [p_scst]
     Masters: [ hpms02 ]
     Slaves: [ hpms01 ]
 Clone Set: cl_lock [g_lock]
     Started: [ hpms01 hpms02 ]
 
Migration summary:
* Node hpms02:
* Node hpms01:
```

we can see it joins the cluster with no errors and Multipath on the client detects this:

```
root@proxmox01:~# multipath -ll
mpatha (23530396637643733) dm-3 SCST_BIO,vg1
size=20G features='2 queue_if_no_path retain_attached_hw_handler' hwhandler='1 alua' wp=rw
|-+- policy='round-robin 0' prio=50 status=active
| |- 8:0:0:0 sdc 8:32 active ready running
| `- 9:0:0:0 sdb 8:16 active ready running
`-+- policy='round-robin 0' prio=10 status=enabled
  |- 7:0:0:0 sdd 8:48 active ready running
  `- 6:0:0:0 sda 8:0  active ready running
```

but compared to the state before reboot we can see that the second path stays as primary and the previous primary is a backup one now since the iSCSI switched to the other node to become Master.

## Raw disk testing

Sequential reads and writes:

```
root@proxmox01:~# fio --bs=4M --direct=1 --rw=read --ioengine=libaio --iodepth=64 --name=/dev/mapper/mpatha --runtime=60
/dev/mapper/mpatha: (g=0): rw=read, bs=4M-4M/4M-4M/4M-4M, ioengine=libaio, iodepth=64
fio-2.1.11
Starting 1 process
Jobs: 1 (f=1): [R(1)] [36.0% done] [0KB/0KB/0KB /s] [0/0/0 iops] [eta 01m:50s]     
/dev/mapper/mpatha: (groupid=0, jobs=1): err= 0: pid=6920: Thu Mar 10 16:29:40 2016
  read : io=7612.0MB, bw=126628KB/s, iops=30, runt= 61556msec
    slat (usec): min=285, max=51033, avg=1581.12, stdev=4362.51
    clat (msec): min=28, max=5324, avg=2048.51, stdev=1145.08
     lat (msec): min=29, max=5325, avg=2050.09, stdev=1145.58
    clat percentiles (msec):
     |  1.00th=[   95],  5.00th=[  273], 10.00th=[  515], 20.00th=[  979],
     | 30.00th=[ 1139], 40.00th=[ 1516], 50.00th=[ 2212], 60.00th=[ 2606],
     | 70.00th=[ 2769], 80.00th=[ 2999], 90.00th=[ 3490], 95.00th=[ 4015],
     | 99.00th=[ 4424], 99.50th=[ 4752], 99.90th=[ 5276], 99.95th=[ 5342],
     | 99.99th=[ 5342]
    bw (KB  /s): min= 2946, max=172298, per=100.00%, avg=127106.71, stdev=32315.94
    lat (msec) : 50=0.32%, 100=1.00%, 250=3.31%, 500=4.94%, 750=4.57%
    lat (msec) : 1000=7.30%, 2000=24.44%, >=2000=54.13%
  cpu          : usr=0.14%, sys=5.39%, ctx=2840, majf=0, minf=65543
  IO depths    : 1=0.1%, 2=0.1%, 4=0.2%, 8=0.4%, 16=0.8%, 32=1.7%, >=64=96.7%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=99.9%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.1%, >=64=0.0%
     issued    : total=r=1903/w=0/d=0, short=r=0/w=0/d=0
     latency   : target=0, window=0, percentile=100.00%, depth=64
Run status group 0 (all jobs):
   READ: io=7612.0MB, aggrb=126627KB/s, minb=126627KB/s, maxb=126627KB/s, mint=61556msec, maxt=61556msec
 
root@proxmox01:~# fio --bs=4K --direct=1 --rw=write --ioengine=libaio --iodepth=64 --name=/dev/mapper/mpatha --runtime=60
/dev/mapper/mpatha: (g=0): rw=write, bs=4K-4K/4K-4K/4K-4K, ioengine=libaio, iodepth=64
fio-2.1.11
Starting 1 process
Jobs: 1 (f=1): [W(1)] [0.2% done] [0KB/1013KB/0KB /s] [0/253/0 iops] [eta 10h:06m:05s]
/dev/mapper/mpatha: (groupid=0, jobs=1): err= 0: pid=7535: Thu Mar 10 16:42:42 2016
  write: io=35368KB, bw=601738B/s, iops=146, runt= 60187msec
    slat (usec): min=7, max=82441, avg=122.22, stdev=1017.52
    clat (msec): min=49, max=1506, avg=435.47, stdev=171.66
     lat (msec): min=49, max=1506, avg=435.60, stdev=171.64
    clat percentiles (msec):
     |  1.00th=[  130],  5.00th=[  196], 10.00th=[  237], 20.00th=[  302],
     | 30.00th=[  338], 40.00th=[  371], 50.00th=[  408], 60.00th=[  445],
     | 70.00th=[  506], 80.00th=[  570], 90.00th=[  652], 95.00th=[  750],
     | 99.00th=[  963], 99.50th=[ 1012], 99.90th=[ 1303], 99.95th=[ 1352],
     | 99.99th=[ 1500]
    bw (KB  /s): min=  115, max= 1226, per=100.00%, avg=588.72, stdev=190.46
    lat (msec) : 50=0.01%, 100=0.24%, 250=11.72%, 500=57.17%, 750=25.84%
    lat (msec) : 1000=4.48%, 2000=0.54%
  cpu          : usr=0.39%, sys=1.69%, ctx=6620, majf=0, minf=7
  IO depths    : 1=0.1%, 2=0.1%, 4=0.1%, 8=0.1%, 16=0.2%, 32=0.4%, >=64=99.3%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.1%, >=64=0.0%
     issued    : total=r=0/w=8842/d=0, short=r=0/w=0/d=0
     latency   : target=0, window=0, percentile=100.00%, depth=64
Run status group 0 (all jobs):
  WRITE: io=35368KB, aggrb=587KB/s, minb=587KB/s, maxb=587KB/s, mint=60187msec, maxt=60187msec
```

The device shows throughput of around 126MB/s for reads and 5.8MB/s for writes with 4K block size.

Random reads and writes:

```
root@proxmox01:~# fio --bs=4k --direct=1 --rw=randread --ioengine=libaio --iodepth=64 --name=/dev/mapper/mpatha --runtime=60
/dev/mapper/mpatha: (g=0): rw=randread, bs=4K-4K/4K-4K/4K-4K, ioengine=libaio, iodepth=64
fio-2.1.11
Starting 1 process
Jobs: 1 (f=1): [r(1)] [100.0% done] [10450KB/0KB/0KB /s] [2612/0/0 iops] [eta 00m:00s]
/dev/mapper/mpatha: (groupid=0, jobs=1): err= 0: pid=7246: Thu Mar 10 16:36:43 2016
  read : io=571136KB, bw=9516.5KB/s, iops=2379, runt= 60016msec
    slat (usec): min=6, max=20178, avg=57.84, stdev=451.54
    clat (usec): min=795, max=612854, avg=26832.35, stdev=24196.91
     lat (msec): min=1, max=612, avg=26.89, stdev=24.21
    clat percentiles (msec):
     |  1.00th=[    9],  5.00th=[   12], 10.00th=[   14], 20.00th=[   17],
     | 30.00th=[   19], 40.00th=[   21], 50.00th=[   23], 60.00th=[   25],
     | 70.00th=[   28], 80.00th=[   32], 90.00th=[   39], 95.00th=[   49],
     | 99.00th=[  116], 99.50th=[  165], 99.90th=[  367], 99.95th=[  424],
     | 99.99th=[  611]
    bw (KB  /s): min= 1080, max=12392, per=100.00%, avg=9573.66, stdev=2173.80
    lat (usec) : 1000=0.01%
    lat (msec) : 2=0.01%, 4=0.05%, 10=2.16%, 20=34.38%, 50=58.86%
    lat (msec) : 100=3.34%, 250=1.01%, 500=0.17%, 750=0.04%
  cpu          : usr=3.45%, sys=10.35%, ctx=99945, majf=0, minf=70
  IO depths    : 1=0.1%, 2=0.1%, 4=0.1%, 8=0.1%, 16=0.1%, 32=0.1%, >=64=100.0%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.1%, >=64=0.0%
     issued    : total=r=142784/w=0/d=0, short=r=0/w=0/d=0
     latency   : target=0, window=0, percentile=100.00%, depth=64
Run status group 0 (all jobs):
   READ: io=571136KB, aggrb=9516KB/s, minb=9516KB/s, maxb=9516KB/s, mint=60016msec, maxt=60016msec
 
root@proxmox01:~# fio --bs=4k --direct=1 --rw=randwrite --ioengine=libaio --iodepth=64 --name=/dev/mapper/mpatha --runtime=60
/dev/mapper/mpatha: (g=0): rw=randwrite, bs=4K-4K/4K-4K/4K-4K, ioengine=libaio, iodepth=64
fio-2.1.11
Starting 1 process
Jobs: 1 (f=1): [w(1)] [0.1% done] [0KB/163KB/0KB /s] [0/40/0 iops] [eta 01d:06h:34m:44s]
/dev/mapper/mpatha: (groupid=0, jobs=1): err= 0: pid=7400: Thu Mar 10 16:40:10 2016
  write: io=11864KB, bw=199525B/s, iops=48, runt= 60888msec
    slat (usec): min=8, max=13359, avg=143.63, stdev=655.08
    clat (msec): min=63, max=3869, avg=1313.34, stdev=593.31
     lat (msec): min=63, max=3869, avg=1313.48, stdev=593.34
    clat percentiles (msec):
     |  1.00th=[  219],  5.00th=[  424], 10.00th=[  578], 20.00th=[  816],
     | 30.00th=[  979], 40.00th=[ 1123], 50.00th=[ 1270], 60.00th=[ 1401],
     | 70.00th=[ 1565], 80.00th=[ 1762], 90.00th=[ 2089], 95.00th=[ 2442],
     | 99.00th=[ 3032], 99.50th=[ 3228], 99.90th=[ 3720], 99.95th=[ 3851],
     | 99.99th=[ 3884]
    bw (KB  /s): min=    4, max=  410, per=99.26%, avg=192.56, stdev=69.40
    lat (msec) : 100=0.07%, 250=1.38%, 500=5.77%, 750=8.93%, 1000=14.46%
    lat (msec) : 2000=57.48%, >=2000=11.90%
  cpu          : usr=0.23%, sys=0.78%, ctx=2792, majf=0, minf=7
  IO depths    : 1=0.1%, 2=0.1%, 4=0.1%, 8=0.3%, 16=0.5%, 32=1.1%, >=64=97.9%
     submit    : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.0%, >=64=0.0%
     complete  : 0=0.0%, 4=100.0%, 8=0.0%, 16=0.0%, 32=0.0%, 64=0.1%, >=64=0.0%
     issued    : total=r=0/w=2966/d=0, short=r=0/w=0/d=0
     latency   : target=0, window=0, percentile=100.00%, depth=64
Run status group 0 (all jobs):
  WRITE: io=11864KB, aggrb=194KB/s, minb=194KB/s, maxb=194KB/s, mint=60888msec, maxt=60888msec
```

The device shows read throughput of 2612 iops and 40 iops for writing, so much faster reading then writing in this case.

## File system load testing

I will use XFS for the test.

```
root@proxmox01:~# mkfs -t xfs /dev/mapper/mpatha
meta-data=/dev/mapper/mpatha     isize=256    agcount=16, agsize=327616 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=0        finobt=0
data     =                       bsize=4096   blocks=5241856, imaxpct=25
         =                       sunit=1      swidth=128 blks
naming   =version 2              bsize=4096   ascii-ci=0 ftype=0
log      =internal log           bsize=4096   blocks=2560, version=2
         =                       sectsz=512   sunit=1 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
 
root@proxmox01:~# mkdir -p /share
root@proxmox01:~# mount /dev/mapper/mpatha /share -o _netdev,noatime,nodiratime,rw
root@proxmox01:~# cat /proc/mounts | grep share
/dev/mapper/mpatha /share xfs rw,noatime,nodiratime,attr2,inode64,sunit=8,swidth=1024,noquota 0 0
```

Now simple dd test bypassing the file system caches and disk buffers:

```
root@proxmox01:~# echo 3 > /proc/sys/vm/drop_caches
root@proxmox01:~# dd if=/dev/zero of=/share/test.img bs=1024K count=1500 oflag=direct conv=fsync && sync;sync
1500+0 records in
1500+0 records out
1572864000 bytes (1.6 GB) copied, 198.26 s, 7.9 MB/s
 
root@proxmox01:~# echo 3 > /proc/sys/vm/drop_caches
root@proxmox01:~# dd if=/share/test.img of=/dev/null iflag=nocache oflag=nocache,sync
3072000+0 records in
3072000+0 records out
1572864000 bytes (1.6 GB) copied, 41.4182 s, 38.0 MB/s
```

So, without any help of caches, we get speed of 8MB/s for writes and 38MB/s for reads for 1MB block size.

{% include series.html %}