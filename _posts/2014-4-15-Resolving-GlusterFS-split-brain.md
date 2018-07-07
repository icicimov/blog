---
type: posts
header:
  teaser: 'blue-abstract-glass-balls-809x412.jpg'
title: 'Resolving GlusterFS split brain'
categories: 
  - High-Availability
tags: [glusterfs, cluster]
date: 2014-4-15
---

I was running a load test against our Staging stack the other day and noticed that application broke down at around 100 users under Siege. Checking the logs reveled that the AMQ servers were down and restarting them was unsuccessful. Further investigation showed a problem with the GlusterFS shared storage.

# Troubleshooting

My assumption is that due to network overload the cluster nodes lost communication between each other and from that moment onward their writes became uncoordinated and their file system out of sync. In case like this the cluster will try to heal it self.

To check for split brain we run the following command that will show us if the cluster is in state of healing:

```
root@ip-172-31-17-31:~# gluster volume heal gfs-volume-stage info
Gathering Heal info on volume gfs-volume-stage has been successful
 
Brick ip-172-31-17-31:/data
Number of entries: 1
/activemq-data/journal/control.dat
 
Brick ip-172-31-11-31:/data
Number of entries: 1
/activemq-data/journal/control.dat
 
 
root@ip-172-31-11-31:~# gluster volume heal gfs-volume-stage info
Gathering Heal info on volume gfs-volume-stage has been successful
 
Brick ip-172-31-17-31:/data
Number of entries: 1
/activemq-data/journal/control.dat
 
Brick ip-172-31-11-31:/data
Number of entries: 1
/activemq-data/journal/control.dat
```

This shows that we have one file split-brained and that's the AMQ journal file that the cluster can't read. We need to manually delete it on one of the servers. We can also see the following error in the GlusterFS log file:

```
root@ip-172-31-17-31:~# less /var/log/glusterfs/glustershd.log
 
[2014-04-10 20:29:59.126943] E [afr-self-heal-data.c:764:afr_sh_data_fxattrop_fstat_done] 0-gfs-volume-stage-replicate-0: Unable to self-heal contents of '<gfid:0e9cc995-acb2-4d80-aedf-1b4f12c9870b>' (possible split-brain). Please delete the file from all but the preferred subvolume.
```

To double check we run:

```
root@ip-172-31-17-31:~# find /data/ -samefile /data/activemq-data/journal/control.dat -print
/data/.glusterfs/0e/9c/0e9cc995-acb2-4d80-aedf-1b4f12c9870b
/data/activemq-data/journal/control.dat

and after we confirm it is the same file we delete it on this cluster node:
 
root@ip-172-31-17-31:~# find /data/ -samefile /data/activemq-data/journal/control.dat -print -delete
/data/.glusterfs/0e/9c/0e9cc995-acb2-4d80-aedf-1b4f12c9870b
/data/activemq-data/journal/control.dat
```

We need to decide which one to delete and keep the other one, as in any other case of manual split-brain resolution, so we don't lose all the AMQ data. In this case I kept the one with most recent modify time stamp.

Then we unmount the GlusterFS storage from the clients after we stop the service (in this case it had crushed so no need for that):

```
root@amq-broker1-stage:~# service activemq stop
root@amq-broker1-stage:~# umount /data
```

And restart the cluster service on both nodes:

```
root@ip-172-31-17-31:~# service glusterfs-server stop
root@ip-172-31-17-31:~# service glusterfs-server start
```

Then we mount back the glusterfs on the client servers:

```
root@amq-broker1-stage:~# service mounting-glusterfs start
root@amq-broker1-stage:~# service activemq start
```

After that the AMQ service for running again and new journal control file got created:

```
root@ip-172-31-17-31:~# ls -l /data/activemq-data/journal/control.dat
-rw-r--r-- 2 root root 160 Apr 11 17:46 /data/activemq-data/journal/control.dat
```

And the cluster was healed too:

```
root@ip-172-31-17-31:~# gluster volume heal gfs-volume-stage info
Gathering Heal info on volume gfs-volume-stage has been successful
 
Brick ip-172-31-17-31:/data
Number of entries: 0
 
Brick ip-172-31-11-31:/data
Number of entries: 0
Preventing the split brain
```

There is quorum parameter that we can tweak to suit our 2 node cluster:

```
root@ip-172-31-17-31:~# gluster volume set gfs-volume-stage cluster.quorum-type fixed
Set volume successful
root@ip-172-31-17-31:~# gluster volume set gfs-volume-stage cluster.quorum-count 2
Set volume successful
```

This means that the writes in the cluster will only be allowed if both cluster members are online. In case they loose connectivity between them the storage will become read-only and none of the peers will be writing in order to prevent inconsistent data. The writes will start again when the link between the peers gets recovered.

```
root@ip-172-31-17-31:~# gluster volume info
  
Volume Name: gfs-volume-stage
Type: Replicate
Volume ID: bb9123b6-6a84-45b8-a9e5-56d040609c2f
Status: Started
Number of Bricks: 1 x 2 = 2
Transport-type: tcp
Bricks:
Brick1: ip-172-31-17-31:/data
Brick2: ip-172-31-11-31:/data
Options Reconfigured:
cluster.quorum-count: 2
cluster.quorum-type: fixed
```

When set to `Auto` quorum is set to be more than half of the bricks in a subvolume, or exactly half if that includes the first listed brick. This setting will also overwrite the `cluster.quorum-type` setting that is valid only for the type of `Fixed`.

# Conclusion

Obviously there is a trade off between the case of allowing and preventing the split brain.

If we allow it, the dependent services will continue working uninterrupted since both reads and writes will be still available for the clients. Although this might be inconsistent depending on the mode they are working in, ie master-master or master-slave, since each of the clients might be connected to a different node and thus start seeing different data from the moment the split-brain occurred. Also when the link between the nodes comes online again they will try to self heal but will not be able to decide which split-brained file(s) version to keep without manual intervention.

In case we prevent it as we did in the above case, the dependent services will be affected since they will not be able to write to the storage any more from the moment the split-brain occurred. In this case though the cluster will continue with normal operation without any manual intervention when the link between the nodes comes online again since the file systems on the both nodes have stayed in sync.
