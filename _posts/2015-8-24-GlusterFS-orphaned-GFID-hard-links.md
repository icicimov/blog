---
type: posts
header:
  teaser: 'blue-abstract-glass-balls-809x412.jpg'
title: 'GlusterFS orphaned GFID hard links'
categories: 
  - High-Availability
tags: [glusterfs, cluster]
date: 2014-8-24
---

Orphaned GlusterFS GFID's are hard links under the `$BRICK/.glusterfs` directory that point to an inode of a file that has been removed manually, outside of the GlusterFS control ie not via client operation or the CLI. Thus this links will never get absorbed by the GlusterFS file system and are of no use at all and we can get read of them to free up some inode space.

When checking for this scenario on our production cluster I ran:

```
[root@ip-172-31-16-36 ~]# find /data/.glusterfs -type f -links -2 -print
/data/.glusterfs/indices/xattrop/xattrop-f805ddba-b680-465b-a3aa-04e6e5011582
```

*NOTE*: We can add the `-path "./??/**/*"` parameter to the above command for extra security as suggested in the comments below. 

So far so good, only one file on the first node. On the second one:

```
[root@ip-172-31-10-36 ~]# find /data/.glusterfs -type f -links -2 -print
/data/.glusterfs/c5/cd/c5cd52ea-1737-4ebe-945e-b8d79e13fb86
/data/.glusterfs/c5/54/c554b554-1339-4fa8-8475-89f936f7b08a
.
.
.
/data/.glusterfs/f4/96/f496fb45-9ebe-4a1d-83d1-7cdf33dd769f
/data/.glusterfs/f4/71/f47145c1-9f81-46fe-a532-ea1734d1a745
/data/.glusterfs/f4/27/f427bba9-a4ff-42a8-8d0f-760a1934f0ee
```

I got around 6570 files returned by this command, all with timestamps dating from July/August. If I remember correctly that was the first time we had an issue with this cluster and we used rsync to recover some files that were written locally instead on the share. Somewhere during this operation these old links were left over.

But before we proceed first lets double check and get some info about one of the orphaned hard links like timestamps, inode number and extended attributes:

```
[root@ip-172-31-10-36 ~]# ls -l /data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c
-rw-r--r-- 1 ec2-user ec2-user 173606 Jul 31  2014 /data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c
 
[root@ip-172-31-10-36 ~]# getfattr -m . -d -e hex /data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c
getfattr: Removing leading '/' from absolute path names
# file: data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c
trusted.afr.gfs-volume-prod-client-0=0x000000000000000000000000
trusted.afr.gfs-volume-prod-client-1=0x000000000000000000000000
trusted.gfid=0x715d4392c44b465c8851c316dd07471c
 
[root@ip-172-31-10-36 ~]# stat -c %i /data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c
14157107
```

Now that we have the file name and inode number we can check all the hard links outside `.glusterfs` sub directory that point to it using one of the following commands:

```
[root@ip-172-31-10-36 ~]# find /data -xdev -inum 14157107 ! -path \*.glusterfs/\* -print
[root@ip-172-31-10-36 ~]# find /data -xdev -samefile /data/.glusterfs/71/5d/715d4392-c44b-465c-8851-c316dd07471c ! -path \*.glusterfs/\* -print
```

Just for completeness here is another way to do it comparing the `trusted.gfid` extended attribute but it's less efficient than the previous too:

```
[root@ip-172-31-10-36 ~]# find /data/ -noleaf -ignore_readdir_race -path /data/.glusterfs -prune -o -type f -print0 | xargs -0 getfattr -m . -n trusted.gfid -e hex | grep 'c316dd07471c'
```

If no files are returned then we can go on and remove the file. To remove all of them in one go we run:

```
[root@ip-172-31-10-36 ~]# find /data/.glusterfs -type f -links -2 -exec rm -fv {} \;
```
