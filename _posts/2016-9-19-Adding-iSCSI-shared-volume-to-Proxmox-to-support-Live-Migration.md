---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Adding iSCSI shared volume to Proxmox to support Live Migration'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, iscsi]
date: 2016-9-19
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

We will use `Multipath` for link HA and improved performance. Install the needed packages first:

```
root@proxmox01:~# apt-get install open-iscsi multipath-tools
```

Then we discover the target and login:

```
root@proxmox01:~# systemctl start open-iscsi.service
 
root@proxmox01:~# iscsiadm -m discovery -t st -p 192.168.0.180
192.168.0.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
10.20.1.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
 
root@proxmox01:~# iscsiadm -m node --login
 
root@proxmox01:~# iscsiadm -m node
10.20.1.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
192.168.0.180:3260,1 iqn.2016-02.local.virtual:virtual.vg1
 
root@proxmox02:~# iscsiadm -m session -P 1
Target: iqn.2016-02.local.virtual:virtual.vg1 (non-flash)
    Current Portal: 10.20.1.180:3260,1
    Persistent Portal: 10.20.1.180:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:674b46a9745
        Iface IPaddress: 10.20.1.186
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 1
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
    Current Portal: 192.168.0.180:3260,1
    Persistent Portal: 192.168.0.180:3260,1
        **********
        Interface:
        **********
        Iface Name: default
        Iface Transport: tcp
        Iface Initiatorname: iqn.1993-08.org.debian:01:674b46a9745
        Iface IPaddress: 192.168.0.186
        Iface HWaddress: <empty>
        Iface Netdev: <empty>
        SID: 2
        iSCSI Connection State: LOGGED IN
        iSCSI Session State: LOGGED_IN
        Internal iscsid Session State: NO CHANGE
 
root@proxmox01:~# lsscsi
[0:0:0:0]    cd/dvd  QEMU     QEMU DVD-ROM     1.4.  /dev/sr0
[2:0:0:0]    disk    SCST_FIO VDISK-LUN01       311  /dev/sdb
[3:0:0:0]    disk    SCST_FIO VDISK-LUN01       311  /dev/sda
```

We can see two new SCSI block devices have been introduced to the system, `/dev/sda` and `/dev/sdb`. Next is `Multipathing` setup. First we find the WWID of the new device:

```
root@proxmox01:~# /lib/udev/scsi_id -g -d /dev/sda
23238363932313833
 
root@proxmox01:~# /lib/udev/scsi_id -g -d /dev/sdb
23238363932313833
```

that we then use in the `Multipath` config file `/etc/multipath.conf` that we create:

```
defaults {
    user_friendly_names    yes
        polling_interval        2
        path_selector           "round-robin 0"
        path_grouping_policy    multibus
        path_checker            readsector0
        getuid_callout          "/lib/udev/scsi_id -g -u -d /dev/%n"
        rr_min_io               100
        failback                immediate
        no_path_retry           queue
}
blacklist {
        wwid .*
}
blacklist_exceptions {
        wwid "23238363932313833"
    property "(ID_SCSI_VPD|ID_WWN|ID_SERIAL)"
}
multipaths {
  multipath {
        wwid "23238363932313833"
        alias mylun
  }
}
```

and after loading Multipath kernel modules:

```
root@proxmox02:~# modprobe -v dm_multipath
insmod /lib/modules/4.2.6-1-pve/kernel/drivers/scsi/device_handler/scsi_dh.ko
insmod /lib/modules/4.2.6-1-pve/kernel/drivers/md/dm-multipath.ko
 
root@proxmox02:~# modprobe -v dm_round_robin
insmod /lib/modules/4.2.6-1-pve/kernel/drivers/md/dm-round-robin.ko
```

and restarting Multipath service/daemon:

```
root@proxmox01:~# systemctl stop multipath-tools.service
root@proxmox01:~# systemctl start multipath-tools.service
root@proxmox02:~# systemctl status -l multipath-tools.service
   multipath-tools.service - LSB: multipath daemon
   Loaded: loaded (/etc/init.d/multipath-tools)
   Active: active (running) since Fri 2016-03-04 17:40:44 AEDT; 6s ago
  Process: 8177 ExecStop=/etc/init.d/multipath-tools stop (code=exited, status=0/SUCCESS)
  Process: 8191 ExecStart=/etc/init.d/multipath-tools start (code=exited, status=0/SUCCESS)
   CGroup: /system.slice/multipath-tools.service
           └─8195 /sbin/multipathd
 
Mar 04 17:40:44 proxmox02 multipath-tools[8191]: Starting multipath daemon: multipathd.
Mar 04 17:40:44 proxmox02 multipathd[8195]: sda: using deprecated getuid callout
Mar 04 17:40:44 proxmox02 multipathd[8195]: sdb: using deprecated getuid callout
Mar 04 17:40:44 proxmox02 multipathd[8195]: mylun: load table [0 41934848 multipath 1 queue_if_no_path 0 1 1 round-robin 0 2 1 8:0 1 8:16 1]
Mar 04 17:40:44 proxmox02 multipathd[8195]: mylun: event checker started
Mar 04 17:40:44 proxmox02 multipathd[8195]: path checkers start up
```

we can see the multipath device `mylun` created:

```
root@proxmox01:~# multipath -ll
mylun (23238363932313833) dm-1 SCST_FIO,VDISK-LUN01
size=20G features='1 queue_if_no_path' hwhandler='0' wp=rw
`-+- policy='round-robin 0' prio=1 status=active
  |- 2:0:0:0 sdb 8:16 active ready running
  `- 3:0:0:0 sda 8:0  active ready running
 
root@proxmox01:~# dmsetup ls
pve-swap    (251:3)
pve-root    (251:0)
mylun    (251:1)
pve-data    (251:4)
vg_drbd0-vm--107--disk--1    (251:5)
vg_proxmox-lv_proxmox    (251:2)
```

Next we create the volume group on one node only:

```
root@proxmox01:~# pvcreate /dev/mapper/mylun
root@proxmox01:~# vgcreate vg_iscsi /dev/mapper/mylun
```

Finally, using the PVE web GUI, we add new LVM storage using the newly created `vg_iscsi` volume group in the `Datacenter` and set it as `Active` and `Shared`.

At the end, in order to log in and establish the sessions to the iSCSI targets on reboot we set the startup mode to `automatic` in the `iscsi initiator` config file `/etc/iscsi/iscsid.conf`:

```
[...]
node.startup = automatic
[...]
```

We can see all the shared VG's and volumes created in the cluster on both nodes for all 3 storage types we have setup above:

```
root@proxmox01:~# vgs
  VG         #PV #LV #SN Attr   VSize  VFree
  pve          1   3   0 wz--n- 31.87g  3.87g
  vg_drbd0     1   1   0 wz--n-  9.31g  3.31g
  vg_drbd1     1   1   0 wz--n- 11.68g  5.68g
  vg_iscsi     1   1   0 wz--n- 19.99g 13.99g
  vg_proxmox   1   1   0 wz--n- 20.00g     0
root@proxmox01:~# lvs
  LV            VG         Attr       LSize  Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  data          pve        -wi-ao---- 16.38g                                                   
  root          pve        -wi-ao----  7.75g                                                   
  swap          pve        -wi-ao----  3.88g                                                   
  vm-107-disk-1 vg_drbd0   -wi-ao----  6.00g                                                   
  vm-106-disk-1 vg_drbd1   -wi-------  6.00g                                                   
  vm-108-disk-1 vg_iscsi   -wi-------  6.00g                                                   
  lv_proxmox    vg_proxmox -wi-ao---- 20.00g
 
root@proxmox02:~# vgs
  VG         #PV #LV #SN Attr   VSize  VFree
  pve          1   3   0 wz--n- 31.87g  3.87g
  vg_drbd0     1   1   0 wz--n-  9.31g  3.31g
  vg_drbd1     1   1   0 wz--n- 11.68g  5.68g
  vg_iscsi     1   1   0 wz--n- 19.99g 13.99g
  vg_proxmox   1   1   0 wz--n- 20.00g     0
root@proxmox02:~# lvs
  LV            VG         Attr       LSize  Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  data          pve        -wi-ao---- 16.38g                                                   
  root          pve        -wi-ao----  7.75g                                                   
  swap          pve        -wi-ao----  3.88g                                                   
  vm-107-disk-1 vg_drbd0   -wi-------  6.00g                                                   
  vm-106-disk-1 vg_drbd1   -wi-ao----  6.00g                                                   
  vm-108-disk-1 vg_iscsi   -wi-ao----  6.00g                                                   
  lv_proxmox    vg_proxmox -wi-ao---- 20.00g
```

{% include series.html %}