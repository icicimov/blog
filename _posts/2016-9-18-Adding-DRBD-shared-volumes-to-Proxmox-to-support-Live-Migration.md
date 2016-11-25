---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Adding Adding DRBD shared volumes to Proxmox to support Live Migration'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, drbd]
date: 2016-9-18
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

The plan is to create 2 resources in `Primary/Primary` mode. The first one `r0` will be used to store disk images for VM's running on `proxmox01` and `r1` for the VM's running on `proxmox02`. This way we can easily recover from split brain in that way that for r0 we can discard all the changes from proxmox02 and for r1 all the changes from proxmox01.

Then we will create LVM volume from each of the resources and add that as shared LVM storage to the PVE Datacenter. PVE 4.x comes with DRBD 9.0.x installed:

```
root@proxmox02:~# modinfo drbd
filename:       /lib/modules/4.4.6-1-pve/kernel/drivers/block/drbd/drbd.ko
alias:          block-major-147-*
license:        GPL
version:        9.0.2-1
description:    drbd - Distributed Replicated Block Device v9.0.2-1
author:         Philipp Reisner <phil@linbit.com>, Lars Ellenberg <lars@linbit.com>
srcversion:     17486A03B4EFD83FC6539BB
depends:        libcrc32c
vermagic:       4.4.6-1-pve SMP mod_unload modversions
parm:           minor_count:Approximate number of drbd devices (1-255) (uint)
parm:           disable_sendpage:bool
parm:           allow_oos:DONT USE! (bool)
parm:           enable_faults:int
parm:           fault_rate:int
parm:           fault_count:int
parm:           fault_devs:int
parm:           two_phase_commit_fail:int
parm:           usermode_helper:string
```

First we configure the common parameters in `/etc/drbd.d/global_common.conf`:

```
global {
    usage-count yes;
    # minor-count dialog-refresh disable-ip-verification
    # cmd-timeout-short 5; cmd-timeout-medium 121; cmd-timeout-long 600;
}
 
common {
    handlers {
        # These are EXAMPLE handlers only.
        # They may have severe implications,
        # like hard resetting the node under certain circumstances.
        # Be careful when chosing your poison.
 
        # pri-on-incon-degr "/usr/lib/drbd/notify-pri-on-incon-degr.sh; /usr/lib/drbd/notify-emergency-reboot.sh; echo b > /proc/sysrq-trigger ; reboot -f";
        # pri-lost-after-sb "/usr/lib/drbd/notify-pri-lost-after-sb.sh; /usr/lib/drbd/notify-emergency-reboot.sh; echo b > /proc/sysrq-trigger ; reboot -f";
        # local-io-error "/usr/lib/drbd/notify-io-error.sh; /usr/lib/drbd/notify-emergency-shutdown.sh; echo o > /proc/sysrq-trigger ; halt -f";
        # fence-peer "/usr/lib/drbd/crm-fence-peer.sh";
        # split-brain "/usr/lib/drbd/notify-split-brain.sh root";
        # out-of-sync "/usr/lib/drbd/notify-out-of-sync.sh root";
        # before-resync-target "/usr/lib/drbd/snapshot-resync-target-lvm.sh -p 15 -- -c 16k";
        # after-resync-target /usr/lib/drbd/unsnapshot-resync-target-lvm.sh;
    }
 
    startup {
        # wfc-timeout degr-wfc-timeout outdated-wfc-timeout wait-after-sb
        wfc-timeout          300;
        degr-wfc-timeout     120;
        outdated-wfc-timeout 120;
        become-primary-on    both;
    }
 
    options {
        # cpu-mask on-no-data-accessible
    }
 
    disk {
        # size on-io-error fencing disk-barrier disk-flushes
        # disk-drain md-flushes resync-rate resync-after al-extents
        # c-plan-ahead c-delay-target c-fill-target c-max-rate
        # c-min-rate disk-timeout
        resync-rate  40M;
        on-io-error  detach;
        disk-barrier no;
        disk-flushes no;
    }
 
    net {
        # protocol timeout max-epoch-size max-buffers unplug-watermark
        # connect-int ping-int sndbuf-size rcvbuf-size ko-count
        # allow-two-primaries cram-hmac-alg shared-secret after-sb-0pri
        # after-sb-1pri after-sb-2pri always-asbp rr-conflict
        # ping-timeout data-integrity-alg tcp-cork on-congestion
        # congestion-fill congestion-extents csums-alg verify-alg
        # use-rle
        protocol      C;
        fencing       resource-only;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
        allow-two-primaries;
    }
}
```

and then we create the resources, first for r0 we create `/etc/drbd.d/r0.res` file:

```
resource r0 {
    on proxmox01 {
        device           /dev/drbd0 minor 0;
        disk             /dev/vdc1;
        address          ipv4 10.20.1.185:7788;
        meta-disk        internal;
    }
    on proxmox02 {
        device           /dev/drbd0 minor 0;
        disk             /dev/vdc1;
        address          ipv4 10.20.1.186:7788;
        meta-disk        internal;
    }
}
```

and for r` we create `/etc/drbd.d/r`.res` file:

```
root@proxmox01:~# vi /etc/drbd.d/r1.res
resource r1 {
    on proxmox01 {
        device           /dev/drbd1 minor 1;
        disk             /dev/vdc2;
        address          ipv4 10.20.1.185:7789;
        meta-disk        internal;
    }
    on proxmox02 {
        device           /dev/drbd1 minor 1;
        disk             /dev/vdc2;
        address          ipv4 10.20.1.186:7789;
        meta-disk        internal;
    }
}
```

and copy over the files to the second node:

```
root@proxmox01:~# rsync -r /etc/drbd.d/ proxmox02:/etc/drbd.d/
```

Then we start the service and create the resources, we do this on both nodes:

```
# service drbd start
# drbdadm create-md r{0,1}
# drbdadm up r{0,1}
```

Then on one node only we set the resources to Primary state and start the initial sync:

```
root@hpms01:~# drbdadm primary --force r{0,1}
 
root@proxmox01:~# drbdadm status
r0 role:Primary
  disk:UpToDate
  proxmox02 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:85.82
 
r1 role:Primary
  disk:UpToDate
  proxmox02 role:Secondary
    replication:SyncSource peer-disk:Inconsistent done:7.86
```

When that finishes we promote the resources to Primary state on the second node too:

```
root@proxmox02:~# drbdadm primary r{0,1}
 
root@proxmox01:~# drbdadm status
r0 role:Primary
  disk:UpToDate
  proxmox02 role:Primary
    peer-disk:UpToDate
 
r1 role:Primary
  disk:UpToDate
  proxmox02 role:Primary
    peer-disk:UpToDate
```

Then on both nodes we configure LVM in `/etc/lvm/lvm.conf` file to look for volumes on the DRBD devices instead the underlying block devices:

```
[...]
    filter = [ "r|/dev/zd*|", "r|/dev/vdc|", "a|/dev/drbd.*|", "a|/dev/vda|", "a|/dev/vdb|" ]
[...]
```

Next we create the DRBD physical LVM devices:

```
root@proxmox01:~# pvcreate /dev/drbd{0,1}
  Physical volume "/dev/drbd0" successfully created
  Physical volume "/dev/drbd1" successfully created
 
root@proxmox02:~# pvcreate /dev/drbd{0,1}
  Physical volume "/dev/drbd0" successfully created
  Physical volume "/dev/drbd1" successfully created

and create the volume groups on one of the nodes only:
root@proxmox01:~# vgcreate vg_drbd0 /dev/drbd0
  Volume group "vg_drbd0" successfully created
 
root@proxmox01:~# vgcreate vg_drbd1 /dev/drbd1
  Volume group "vg_drbd1" successfully created
```

The groups now can be seen on both nodes thanks to the DRBD replication:

```
root@proxmox01:~# vgs
  VG         #PV #LV #SN Attr   VSize  VFree
  pve          1   3   0 wz--n- 31.87g  3.87g
  vg_drbd0     1   0   0 wz--n-  9.31g  9.31g
  vg_drbd1     1   0   0 wz--n- 11.68g 11.68g
  vg_proxmox   1   1   0 wz--n- 20.00g     0
 
root@proxmox02:~# vgs
  VG         #PV #LV #SN Attr   VSize  VFree
  pve          1   3   0 wz--n- 31.87g  3.87g
  vg_drbd0     1   0   0 wz--n-  9.31g  9.31g
  vg_drbd1     1   0   0 wz--n- 11.68g 11.68g
  vg_proxmox   1   1   0 wz--n- 20.00g     0
```

Then we go to the PVE admin web console and add LVM storage under Datacenter, select vg_drbd0 from drop-down list and check the boxes for active and shared. In the Nodes drop-down list we select both nodes proxmox01 and proxmox02 and click Add. Repeat same for `vg_drbd1`.

{% include series.html %}