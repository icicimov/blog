---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Adding RBD (CEPH) remote cluster storage to Proxmox'
categories: 
  - Virtualization
tags: [kvm, proxmox, high-availability, cluster, rbd, ceph]
date: 2016-9-20
series: "Highly Available Multi-tenant KVM Virtualization with Proxmox PVE and OpenVSwitch"
---

There is a 3 node CEPH cluster running on the office virtualization server that is external to PVE. The latest PVE though has built in support for CEPH using `pveceph` package so in case we have PVE cluster of 3 hosts we can use them to deploy CEPH cluster locally.

The advantage of using CEPH as backend storage is it is highly available replicated storage, provides snapshots and by default it is teen provisioned.

```
root@proxmox02:~# cat /etc/hosts
[...]
192.168.0.117 ceph1.encompass.com   ceph1 
192.168.0.118   ceph2.encompass.com     ceph2
192.168.0.119   ceph3.encompass.com     ceph3

igorc@ceph1:~/ceph-cluster$ ceph -s
    cluster 4804acbf-1adb-45b6-bc49-6fbd90632c65
     health HEALTH_WARN
            mon.ceph1 low disk space
     monmap e1: 3 mons at {ceph1=192.168.0.117:6789/0,ceph2=192.168.0.118:6789/0,ceph3=192.168.0.119:6789/0}
            election epoch 90, quorum 0,1,2 ceph1,ceph2,ceph3
     mdsmap e32: 1/1/1 up {0=ceph1=up:active}
     osdmap e100: 6 osds: 6 up, 6 in
      pgmap v17900: 320 pgs, 5 pools, 1833 MB data, 493 objects
            5672 MB used, 49557 MB / 55229 MB avail
                 320 active+clean

root@ceph2:~# ceph osd tree
ID WEIGHT  TYPE NAME      UP/DOWN REWEIGHT PRIMARY-AFFINITY 
-1 0.05997 root default                                     
-2 0.01999     host ceph1                                   
 0 0.00999         osd.0       up  1.00000          1.00000 
 3 0.00999         osd.3       up  1.00000          1.00000 
-3 0.01999     host ceph2                                   
 1 0.00999         osd.1       up  1.00000          1.00000 
 4 0.00999         osd.4       up  1.00000          1.00000 
-4 0.01999     host ceph3                                   
 2 0.00999         osd.2       up  1.00000          1.00000 
 5 0.00999         osd.5       up  1.00000          1.00000

root@ceph2:~# ceph osd lspools
0 rbd,1 cephfs_data,2 cephfs_metadata,3 datastore,4 images,

root@ceph2:~# rados lspools
rbd
cephfs_data
cephfs_metadata
datastore
images

root@ceph2:~# ceph df
GLOBAL:
    SIZE       AVAIL      RAW USED     %RAW USED 
    55229M     49558M        5671M         10.27 
POOLS:
    NAME                ID     USED      %USED     MAX AVAIL     OBJECTS 
    rbd                 0          0         0        12317M           0 
    cephfs_data         1          0         0        12317M           0 
    cephfs_metadata     2       1962         0        12317M          20 
    datastore           3          0         0        12317M           0 
    images              4      1833M      9.96        12317M         473

root@ceph2:~# rados df
pool name                 KB      objects       clones     degraded      unfound           rd        rd KB           wr        wr KB
cephfs_data                0            0            0            0           0            0            0            0            0
cephfs_metadata            2           20            0            0           0           52           57           31            8
datastore                  0            0            0            0           0            0            0            0            0
images               1877457          473            0            0           0         3150        88655         5025      1804457
rbd                        0            0            0            0           0            0            0            0            0
  total used         5807272          493
  total avail       50748128
  total space       56555400

root@ceph2:~# ceph osd pool get images size
size: 3
root@ceph2:~# ceph osd pool get datastore size
size: 3
```

We have 5 pools in the cluster. The users that have permissions to access are:

```
igorc@ceph1:~/ceph-cluster$ sudo ceph auth list
installed auth entries:
[...]
client.datastore
  key: AQCj1+NVTzcAOhAACiknaftjNpYJllxWRugzmw==
  caps: [mon] allow r
  caps: [osd] allow class-read object_prefix rbd_children, allow rwx pool=datastore
client.images
  key: AQAZ2eNVaUaMNRAAYP4IjZKUdxE/rlZ23gxusA==
  caps: [mon] allow r
  caps: [osd] allow class-read object_prefix rbd_children, allow rwx pool=images
```

The user with access rights to the `images` pool is the `images` user. We get his keyring:

```
igorc@ceph1:~/ceph-cluster$ sudo ceph auth get client.images
exported keyring for client.images
[client.images]
  key = AQAZ2eNVaUaMNRAAYP4IjZKUdxE/rlZ23gxusA==
  caps mon = "allow r"
  caps osd = "allow class-read object_prefix rbd_children, allow rwx pool=images"
```

and we create keyring on the PVE cluster with same name as the Storage ID we want to create, in our case the ID is `ceph_storage` so the key we create is <storage-id>.keyring:

```
root@proxmox02:~# vi /etc/pve/priv/ceph/ceph_storage.keyring 
[client.images]
  key = AQAZ2eNVaUaMNRAAYP4IjZKUdxE/rlZ23gxusA==
  caps mon = "allow r"
  caps osd = "allow class-read object_prefix rbd_children, allow rwx pool=images"
```

We want to use the `images` OSD pool so we configure the RBD storage in the PVE UI so the result config looks like this:

```
root@proxmox02:~# cat /etc/pve/storage.cfg
[...]
rbd: ceph_storage
  monhost 192.168.0.117:6789 192.168.0.118:6789 192.168.0.119:6789
  pool images
  content images
  nodes proxmox02,proxmox01
  krbd
  username images
```

Then we create a VM with vmid of 110 in PVE using the rbd storage for its image. As a result of this now we can see the object created in the pool in the CEPH cluster:

```
igorc@ceph1:~/ceph-cluster$ rbd -p images list
vm-110-disk-1
```

or to find where was the VM image placed as an object in the PG's:

```
root@ceph2:~# ceph osd map images vm-110-disk-1
osdmap e100 pool 'images' (4) object 'vm-110-disk-1' -> pg 4.8c7110fb (4.3b) -> up ([5,3,4], p5) acting ([5,3,4], p5)
```

which tells us this object was placed in PG group 4.3b and OSD's 5, 3 and 4 of which 5 is a primary, which on other hand means it was placed on host ceph3 (from the above output of "ceph osd tree" command osd.5 is on ceph3) and replicated to ceph1 and ceph2.

And on proxmox02 where we initially created the VM we can see a new `rbd` device created:

```
root@proxmox02:~# rbd showmapped
2016-09-08 15:30:30.909559 7f6730598780 -1 did not load config file, using default settings.
id pool   image         snap device    
0  images vm-110-disk-1 -    /dev/rbd0
```

Tested the live migration from proxmox02 to proxmox01 and back and all worked without any issues.

{% include series.html %}