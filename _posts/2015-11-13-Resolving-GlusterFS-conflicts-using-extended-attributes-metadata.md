---
type: posts
header:
  teaser: 'blue-abstract-glass-balls-809x412.jpg'
title: 'Resolving GlusterFS conflicts using extended attributes metadata'
categories: 
  - High-Availability
tags: [glusterfs, cluster]
date: 2015-11-13
---

This is a walk through example of resolution of conflict created as result of split-brain.

On the first node we have the following data for the file:

```
[root@ip-172-31-10-36 ~]# getfattr -m . -d -e hex /data/activemq-data/db-1755.log
getfattr: Removing leading '/' from absolute path names
# file: data/activemq-data/db-1755.log
trusted.afr.gfs-volume-prod-client-0=0x000000610000000000000000
trusted.afr.gfs-volume-prod-client-1=0x000000000000000000000000
trusted.gfid=0x8ee3e44467464c4f96429eca42ffc629
```

and on the second one:

```
[root@ip-172-31-16-36 ~]# getfattr -m . -d -e hex /data/activemq-data/db-1755.log
getfattr: Removing leading '/' from absolute path names
# file: data/activemq-data/db-1755.log
trusted.afr.gfs-volume-prod-client-0=0x000000000000000000000000
trusted.afr.gfs-volume-prod-client-1=0x000000000000000000000000
trusted.gfid=0x8ee3e44467464c4f96429eca42ffc629
```

So the first server ip-172-31-10-36 shows data discripancy for the file in its changelog where for the second server ip-172-31-16-36 all is fine (all zeroes). To check who is right we get some file stats from both peers:

```
[root@ip-172-31-10-36 ~]# md5sum /data/activemq-data/db-1755.log
69c6bbf5d7cdec4ad247127f653be1f2  /data/activemq-data/db-1755.log
 
[root@ip-172-31-10-36 ~]# stat /data/activemq-data/db-1755.log
  File: `/data/activemq-data/db-1755.log'
  Size: 41675807      Blocks: 81408      IO Block: 4096   regular file
Device: ca90h/51856d    Inode: 1321485     Links: 2
Access: (0644/-rw-r--r--)  Uid: (    0/    root)   Gid: (    0/    root)
Access: 2015-11-13 11:10:48.234230950 +1100
Modify: 2015-11-12 11:15:58.273591276 +1100
Change: 2015-11-12 11:15:58.274591250 +1100
```

and on the second one:

```
[root@ip-172-31-16-36 ~]# md5sum /data/activemq-data/db-1755.log
29360fe3c780b016ec65ca5c41a2064c  /data/activemq-data/db-1755.log
 
[root@ip-172-31-16-36 ~]# stat /data/activemq-data/db-1755.log
  File: `/data/activemq-data/db-1755.log'
  Size: 33030144      Blocks: 57352      IO Block: 4096   regular file
Device: ca90h/51856d    Inode: 30420794    Links: 2
Access: (0644/-rw-r--r--)  Uid: (    0/    root)   Gid: (    0/    root)
Access: 2015-11-13 11:10:41.663121933 +1100
Modify: 2015-11-12 11:15:49.081800000 +1100
Change: 2015-11-12 11:15:49.188802118 +1100
```

Obviously the file content is different. This is clear example of data split-brain caused by peers loosing communication ie the brick on the second server went offline. To resolve this we have to decide which file to keep and delete the same on the other brick so it can get pooled back from the healthy one. In other words we have to declare one of the nodes as split-brain `victim` globally for each file we find in split-brain state or per individual file bases.

Now if we check the file state on the client side:

```
root@amq-broker1-prod:~# stat /data/activemq-data/db-1755.log
  File: `/data/activemq-data/db-1755.log'
  Size: 41675807      Blocks: 81399      IO Block: 131072 regular file
Device: 13h/19d    Inode: 10827391045696734761  Links: 1
Access: (0644/-rw-r--r--)  Uid: (    0/    root)   Gid: (    0/    root)
Access: 2015-11-13 11:10:48.234230950 +1100
Modify: 2015-11-12 11:15:58.273591276 +1100
Change: 2015-11-12 11:15:58.274591250 +1100
 Birth: -
 
root@amq-broker2-prod:~# stat /data/activemq-data/db-1755.log
  File: `/data/activemq-data/db-1755.log'
  Size: 41675807      Blocks: 81399      IO Block: 131072 regular file
Device: 13h/19d    Inode: 10827391045696734761  Links: 1
Access: (0644/-rw-r--r--)  Uid: (    0/    root)   Gid: (    0/    root)
Access: 2015-11-13 11:10:48.234230950 +1100
Modify: 2015-11-12 11:15:58.273591276 +1100
Change: 2015-11-12 11:15:58.274591250 +1100
 Birth: -
```

we can confirm the clients have mounted the volume from the first server ip-172-31-10-36. Also the file size matches what the first brick is reporting so we can go on and delete it on the second one, our split-brain victim:

```
# find /data/ -samefile /data/activemq-data/db-1755.log -print -delete
```

The problem with this command is that it has to crawl down the brick's directory structure which can be very slow for big volumes. In that case we can use:

```
# gfid=$(getfattr -n trusted.gfid --absolute-names -e hex /data/activemq-data/db-1755.log | grep 0x | cut -d'x' -f2) && rm -f /data/activemq-data/db-1755.log && rm -f /data/.glusterfs/${gfid:0:2}/${gfid:2:2}/${gfid:0:8}-${gfid:8:4}-${gfid:12:4}-${gfid:16:4}-${gfid:20:12}
```

which is much faster. After that if the self-healing process is running for the volume and both bricks are online the file will be automatically replicated on the next run or when the file is being accessed on the client side. If not we have to run it manually:

```
# gluster volume heal gfs-volume-prod full
```