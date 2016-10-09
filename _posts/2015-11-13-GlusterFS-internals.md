---
type: posts
title: 'GlusterFS internals'
categories: 
  - "High-Availability"
tags: [glusterfs, cluster, infrastructure, high-availability]
---

GlusterFS stores metadata info in extended attributes which is supported and enabled by default in the XFS file system we use for the bricks. This is different approach then some other distributed storage cluster systems like Ceph for example that have separate metadata service running instead.

Each extended attribute has a value which is 24 hexa decimal digits. First 8 digits represent changelog of data. Second 8 digits represent changelog of metadata. Last 8 digits represent Changelog of directory entries.

```
0x 000003d7 00000001 00000000
        |      |       |
        |      |        \_ changelog of directory entries
        |       \_ changelog of metadata
         \ _ changelog of data
```

The metadata and entry changelogs are valid for directories. For regular files data and metadata changelogs are valid. For special files like device files etc. the metadata changelog is valid. When a file split-brain happens it could be either data split-brain or meta-data split-brain or both.

Version 3.3 introduced a new structure to the bricks, the `.glusterfs` directory. The `GFID` is used to build the structure of the `.glusterfs` directory in the brick. Each file is hardlinked to a path that takes the first two digits and makes a directory, then the next two digits makes the next one, and finally the complete `uuid`. For example:

```
[root@server ~]# getfattr -m . -d -e hex /data/activemq-data/db-1755.log
getfattr: Removing leading '/' from absolute path names
# file: data/activemq-data/db-1755.log
trusted.afr.gfs-volume-prod-client-0=0x000000610000000000000000
trusted.afr.gfs-volume-prod-client-1=0x000000000000000000000000
trusted.gfid=0x8ee3e44467464c4f96429eca42ffc629
```

in our case should make a hardlink to:

```
/data/.glusterfs/8e/e3/8ee3e444-6746-4c4f-9642-9eca42ffc629
```

as we can confirm on the file system:

```
[root@server ~]# ls -l /data/.glusterfs/8e/e3/8ee3e444-6746-4c4f-9642-9eca42ffc629
-rw-r--r-- 2 root root 41675807 Nov 12 11:15 /data/.glusterfs/8e/e3/8ee3e444-6746-4c4f-9642-9eca42ffc629
```

Each directory creates symlink that points to the gfid of themselves within the gfid of their parent.

```
[root@server ~]# getfattr -m . -d -e hex /data/documents/2015-11-12/
getfattr: Removing leading '/' from absolute path names
# file: data/documents/2015-11-12
trusted.afr.gfs-volume-prod-client-0=0x000000000000000000000093
trusted.afr.gfs-volume-prod-client-1=0x000000000000000000000001
trusted.gfid=0xdbd7932e6fda49e1abfb19799a5f50e6
```

which creates the hardlink:

```
[root@server ~]# ls -l /data/.glusterfs/db/d7/dbd7932e-6fda-49e1-abfb-19799a5f50e6
lrwxrwxrwx 1 root root 59 Nov 12 09:36 /data/.glusterfs/db/d7/dbd7932e-6fda-49e1-abfb-19799a5f50e6 -> ../../4b/47/4b470aab-5124-4aa8-9b78-4592afd2c4dd/2015-11-12
```

The consequence of all this is if you delete a file from a brick without deleting it's gfid hardlink, the filename will be restored as part of the self-heal process and that filename will be linked back with it's gfid file. If that gfid file is broken, the filename file will be as well.