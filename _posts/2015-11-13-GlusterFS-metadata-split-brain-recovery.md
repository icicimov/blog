---
type: posts
title: 'GlusterFS metadata split brain recovery'
categories: 
  - "High-Availability"
tags: [glusterfs, cluster]
---

While investigating an error related to failed documents I came across following error in the GlusterFS healing daemon log file:

```
[2015-11-08 23:22:38.700539] E [afr-self-heal-common.c:197:afr_sh_print_split_brain_log] 0-gfs-volume-vol1-replicate-0: Unable to self-heal contents of '<gfid:00000000-0000-0000-0000-000000000001>' (possible split-brain). Please delete the file from all but the preferred subvolume.- Pending matrix:  [ [ 0 2 2 ] [ 2 0 2 ] [ 2 2 0 ] ]
```

This indicates a split brain scenario, ie the cluster members at some point lost communication to each other. To check the daemon status:

```
root@ip-10-133-1-127:~# gluster volume heal gfs-volume-vol1 info
Gathering Heal info on volume gfs-volume-vol1 has been successful
 
Brick ip-10-133-1-127.eu-west-1.compute.internal:/data
Number of entries: 1
/
 
Brick ip-10-133-11-15.eu-west-1.compute.internal:/data
Number of entries: 1
/
 
Brick ip-10-133-111-139.eu-west-1.compute.internal:/data
Number of entries: 1
/
```

Indeed, and the split brain is in the very root of the volume, it's meta data file or more specifically its extended attributes.

```
root@ip-10-133-1-127:~# getfattr -m . -d -e hex /data
getfattr: Removing leading '/' from absolute path names
# file: data
trusted.afr.gfs-volume-vol1-client-0=0x000000000000000000000000
trusted.afr.gfs-volume-vol1-client-1=0x000000000000000200000000
trusted.afr.gfs-volume-vol1-client-2=0x000000000000000200000000
trusted.gfid=0x00000000000000000000000000000001
trusted.glusterfs.dht=0x000000010000000000000000ffffffff
trusted.glusterfs.volume-id=0x7c95e12311014d569fca64fda91e0d4c
 
root@ip-10-133-11-15:~# getfattr -m . -d -e hex /data
getfattr: Removing leading '/' from absolute path names
# file: data
trusted.afr.gfs-volume-vol1-client-0=0x000000000000000200000000
trusted.afr.gfs-volume-vol1-client-1=0x000000000000000000000000
trusted.afr.gfs-volume-vol1-client-2=0x000000000000000200000000
trusted.gfid=0x00000000000000000000000000000001
trusted.glusterfs.dht=0x000000010000000000000000ffffffff
trusted.glusterfs.volume-id=0x7c95e12311014d569fca64fda91e0d4c
 
root@ip-10-133-111-139:~# getfattr -m . -d -e hex /data
getfattr: Removing leading '/' from absolute path names
# file: data
trusted.afr.gfs-volume-vol1-client-0=0x000000000000000200000000
trusted.afr.gfs-volume-vol1-client-1=0x000000000000000200000000
trusted.afr.gfs-volume-vol1-client-2=0x000000000000000000000000
trusted.gfid=0x00000000000000000000000000000001
trusted.glusterfs.dht=0x000000010000000000000000ffffffff
trusted.glusterfs.volume-id=0x7c95e12311014d569fca64fda91e0d4c
```

What we need to look at here is the `trusted.afr` attribute. The first 8 hex characters after '0x' of this attribute are representing the data changelog, the second 8 the metadata changelog and the third group is valid for directories only. If the value of the group is '00000000' that means that brick has applied valid changes locally. So what we can see here is that the values of the `xattr` for the metadata changelog on each brick are different and each brick thinks it has the correct metadata and the other two don't. Please see [GlusterFS internals]({% post_url 2015-11-13-GlusterFS-internals %}) for more details on GLusterFS extended attributes.

Lets find the file location:

```
root@ip-10-133-1-127:~# find /data/ -name 00000000-0000-0000-0000-000000000001 -ls
134320193    0 lrwxrwxrwx   1 root     root            8 Jan 11  2015 /data/.glusterfs/00/00/00000000-0000-0000-0000-000000000001 -> ../../..
67108930    0 ----------   2 root     root            0 Jan 11  2015 /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
```

Now we have two options, we can delete this file on all servers but one and let it replicate or we can reset its extended attributes in case the file content is same on all nodes.

```
root@ip-10-133-1-127:~# md5sum /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
d41d8cd98f00b204e9800998ecf8427e  /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
 
root@ip-10-133-11-15:~# md5sum /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
d41d8cd98f00b204e9800998ecf8427e  /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
 
root@ip-10-133-111-139:~# md5sum /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
d41d8cd98f00b204e9800998ecf8427e  /data/.glusterfs/indices/xattrop/00000000-0000-0000-0000-000000000001
```

In this case all 3 bricks have same file content so we can go and reset the xattribute since we also know the I/O of the clients are not affected, they can read and write files from the share with no issues. On all 3 bricks we run:

```
root@ip-10-133-1-127:~# setfattr -n trusted.afr.gfs-volume-vol1-client-0 -v 0x000000000000000000000000 /data/
root@ip-10-133-1-127:~# setfattr -n trusted.afr.gfs-volume-vol1-client-1 -v 0x000000000000000000000000 /data/
root@ip-10-133-1-127:~# setfattr -n trusted.afr.gfs-volume-vol1-client-2 -v 0x000000000000000000000000 /data/
```

And check the healing daemon status again:

```
root@ip-10-133-1-127:~# gluster volume heal gfs-volume-vol1 info
Gathering Heal info on volume gfs-volume-vol1 has been successful
 
Brick ip-10-133-1-127.eu-west-1.compute.internal:/data
Number of entries: 0
 
Brick ip-10-133-11-15.eu-west-1.compute.internal:/data
Number of entries: 0
 
Brick ip-10-133-111-139.eu-west-1.compute.internal:/data
Number of entries: 0
```

The problem is gone.