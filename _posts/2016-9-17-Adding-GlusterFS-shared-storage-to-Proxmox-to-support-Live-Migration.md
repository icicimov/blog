---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Adding GlusterFS shared storage to Proxmox to support Live Migration'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, glusterfs]
date: 2016-9-17
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

To be able to move VM's from one cluster member to another their root, and in fact any other attached disk, needs to be created on a shared storage. PVE has built in support for the native GlusterFS client among the other storage types which include LVM, NFS, iSCSI, RBD, ZFS and ZFS over iSCSI.

## Prepare the volumes

The whole procedure executed on both nodes is given below:

```
root@proxmox01:~# fdisk -l /dev/vdb
Disk /dev/vdb: 20 GiB, 21474836480 bytes, 41943040 sectors
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 512 bytes
I/O size (minimum/optimal): 512 bytes / 512 bytes
 
root@proxmox01:~# pvcreate /dev/vdb
  Physical volume "/dev/vdb" successfully created
 
root@proxmox01:~# vgcreate vg_proxmox /dev/vdb
  Volume group "vg_proxmox" successfully created
 
root@proxmox01:~# lvcreate --name lv_proxmox -l 100%vg vg_proxmox
  Logical volume "lv_proxmox" created.
 
root@proxmox01:~# mkfs -t xfs -f -i size=512 -n size=8192 -L PROXMOX /dev/vg_proxmox/lv_proxmox
meta-data=/dev/vg_proxmox/lv_proxmox isize=512    agcount=4, agsize=1310464 blks
         =                       sectsz=512   attr=2, projid32bit=1
         =                       crc=0        finobt=0
data     =                       bsize=4096   blocks=5241856, imaxpct=25
         =                       sunit=0      swidth=0 blks
naming   =version 2              bsize=8192   ascii-ci=0 ftype=0
log      =internal log           bsize=4096   blocks=2560, version=2
         =                       sectsz=512   sunit=0 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
 
root@proxmox01:~# mkdir -p /data/proxmox
root@proxmox01:~# vi /etc/fstab
[...]
/dev/mapper/vg_proxmox-lv_proxmox       /data/proxmox xfs       defaults        0 0
  
root@proxmox01:~# mount -a
root@proxmox01:~# mount | grep proxmox
/dev/mapper/vg_proxmox-lv_proxmox on /data/proxmox type xfs (rw,relatime,attr2,inode64,noquota)
```

This created a LVM volume out of `/dev/vdb` disk and formatted it with XFS.

### Install, setup and configure GLusterFS volume

Both nodes (proxmox01 and proxmox02) will run the GlusterFS server and client. The step-by-step procedure is given below, the `10.10.1.0/24` network has been used for the cluster communication:

```
root@proxmox01:~# apt-get install glusterfs-server glusterfs-client
 
root@proxmox01:~# gluster peer probe 10.10.1.186
peer probe: success.
root@proxmox01:~# gluster peer status
Number of Peers: 1
Hostname: 10.10.1.186
Uuid: 516154fa-84c4-437e-b745-97ed7505700e
State: Peer in Cluster (Connected)
 
root@proxmox01:~# gluster volume create gfs-volume-proxmox transport tcp replica 2 10.10.1.185:/data/proxmox 10.10.1.186:/data/proxmox force
volume create: gfs-volume-proxmox: success: please start the volume to access data
 
root@proxmox01:~# gluster volume start gfs-volume-proxmox
volume start: gfs-volume-proxmox: success
 
root@proxmox01:~# gluster volume info
  
Volume Name: gfs-volume-proxmox
Type: Replicate
Volume ID: a8350bda-6e9a-4ccf-ade7-34c98c2197c3
Status: Started
Number of Bricks: 1 x 2 = 2
Transport-type: tcp
Bricks:
Brick1: 10.10.1.185:/data/proxmox
Brick2: 10.10.1.186:/data/proxmox
root@proxmox01:~# gluster volume status
Status of volume: gfs-volume-proxmox
Gluster process                        Port    Online    Pid
------------------------------------------------------------------------------
Brick 10.10.1.185:/data/proxmox                49152    Y    18029
Brick 10.10.1.186:/data/proxmox                49152    Y    6669
NFS Server on localhost                         2049    Y    18043
Self-heal Daemon on localhost                    N/A    Y    18048
NFS Server on 10.10.1.186                       2049    Y    6683
Self-heal Daemon on 10.10.1.186                  N/A    Y    6688
  
Task Status of Volume gfs-volume-proxmox
------------------------------------------------------------------------------
There are no active volume tasks
  
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.cache-size 256MB
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox network.ping-timeout 5
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox cluster.server-quorum-type server
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox cluster.quorum-type fixed
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox cluster.quorum-count 1
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox cluster.eager-lock on
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox network.remote-dio enable
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox cluster.eager-lock enable
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.stat-prefetch off
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.io-cache off
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.read-ahead off
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.quick-read off
volume set: success
root@proxmox01:~# gluster volume set gfs-volume-proxmox performance.readdir-ahead on
volume set: success

root@proxmox01:~# gluster volume info
  
Volume Name: gfs-volume-proxmox
Type: Replicate
Volume ID: a8350bda-6e9a-4ccf-ade7-34c98c2197c3
Status: Started
Number of Bricks: 1 x 2 = 2
Transport-type: tcp
Bricks:
Brick1: 10.10.1.185:/data/proxmox
Brick2: 10.10.1.186:/data/proxmox
Options Reconfigured:
performance.readdir-ahead: on
performance.quick-read: off
performance.read-ahead: off
performance.io-cache: off
performance.stat-prefetch: off
network.remote-dio: enable
cluster.eager-lock: enable
cluster.quorum-count: 1
cluster.quorum-type: fixed
cluster.server-quorum-type: server
network.ping-timeout: 5
performance.cache-size: 256MB

root@proxmox01:~# gluster volume status
Status of volume: gfs-volume-proxmox
Gluster process                             TCP Port  RDMA Port  Online  Pid
------------------------------------------------------------------------------
Brick proxmox01:/data/proxmox               49152     0          Y       4155 
Brick proxmox02:/data/proxmox               49152     0          Y       3762 
NFS Server on localhost                     2049      0          Y       4140 
Self-heal Daemon on localhost               N/A       N/A        Y       4146 
NFS Server on proxmox02                     2049      0          Y       3746 
Self-heal Daemon on proxmox02               N/A       N/A        Y       3756 
 
Task Status of Volume gfs-volume-proxmox
------------------------------------------------------------------------------
There are no active volume tasks
```

## Configure the client

Now we go to the Proxmox GUI and add GLusterFS type of storage to the Datacenter. Proxmox has built-in support for the GLusterFS native client and this action will result with the following mount point created by PVE on both servers:

```
# mount | grep proxmox
10.10.1.185:gfs-volume-proxmox on /mnt/pve/proxmox type fuse.glusterfs (rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072)
```

**NOTE:** Launching LXC containers on shared storage is not supported

{% include series.html %}