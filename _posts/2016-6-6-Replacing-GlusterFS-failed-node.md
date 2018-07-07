---
type: posts
header:
  teaser: 'blue-abstract-glass-balls-809x412.jpg'
title: 'Replacing GlusterFS failed node'
categories: 
  - High-Availability
tags: [glusterfs, cluster]
date: 2016-6-6
---

In the following scenario the node 10.66.4.225 has become unresponsive and has been terminated. This leaves us with the following state on the cluster:

```bash
root@ip-10-66-3-101:~# gluster peer status
Number of Peers: 2
 
Hostname: ip-10-66-4-225.ap-southeast-2.compute.internal
Uuid: e4da23b0-0ffb-432c-b8ea-235067749109
State: Peer in Cluster (Disconnected)
Other names:
10.66.4.225
 
Hostname: 10.66.5.65
Uuid: d6773667-d6de-44c6-8ad9-71af21d5a367
State: Peer in Cluster (Connected)
 
root@ip-10-66-3-101:~# gluster volume status
Status of volume: staging-glusterfs
Gluster process                        Port    Online    Pid
------------------------------------------------------------------------------
Brick 10.66.3.101:/data                    49152   Y    26308
Brick 10.66.5.65:/data                    49152    Y    26095
NFS Server on localhost                    2049    Y    26323
Self-heal Daemon on localhost               N/A    Y    26322
NFS Server on 10.66.5.65                   2049    Y    26109
Self-heal Daemon on 10.66.5.65              N/A    Y    26110
  
Task Status of Volume staging-glusterfs
------------------------------------------------------------------------------
There are no active volume tasks
  
root@ip-10-66-3-101:~# gluster volume status
Status of volume: staging-glusterfs
Gluster process                        Port    Online    Pid
------------------------------------------------------------------------------
Brick 10.66.3.101:/data                   49152    Y    26308
Brick 10.66.5.65:/data                    49152    Y    26095
NFS Server on localhost                    2049    Y    26323
Self-heal Daemon on localhost               N/A    Y    26322
NFS Server on 10.66.5.65                    2049   Y    26109
Self-heal Daemon on 10.66.5.65              N/A    Y    26110
  
Task Status of Volume staging-glusterfs
------------------------------------------------------------------------------
There are no active volume tasks
 
root@ip-10-66-3-101:~# gluster volume info
Volume Name: staging-glusterfs
Type: Replicate
Volume ID: 2a0876ed-2988-46cb-8dea-98c25d092e36
Status: Started
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: 10.66.3.101:/data
Brick2: 10.66.5.65:/data
Brick3: 10.66.4.225:/data
Options Reconfigured:
network.ping-timeout: 5
cluster.quorum-type: auto
performance.cache-size: 256MB
cluster.server-quorum-type: server
```

We configure new GLusterFS node 10.66.4.238 to replace the failed one and we add the new node to the peers list:

```bash
root@ip-10-66-3-101:~# gluster peer probe 10.66.4.238
peer probe: success.
 
root@ip-10-66-3-101:~# gluster peer status
Number of Peers: 3
 
Hostname: ip-10-66-4-225.ap-southeast-2.compute.internal
Uuid: e4da23b0-0ffb-432c-b8ea-235067749109
State: Peer in Cluster (Disconnected)
Other names:
10.66.4.225
 
Hostname: 10.66.5.65
Uuid: d6773667-d6de-44c6-8ad9-71af21d5a367
State: Peer in Cluster (Connected)
 
Hostname: 10.66.4.238
Uuid: b5b9d91f-4943-4247-9b51-d2ecbc465b2b
State: Peer in Cluster (Connected)
```

Now we can replace the old brick/node with the new one:

```bash
root@ip-10-66-3-101:~# gluster volume replace-brick staging-glusterfs 10.66.4.225:/data 10.66.4.238:/data commit force
volume replace-brick: success: replace-brick commit successful
```

after which we start the volume healing process:

```bash
root@ip-10-66-3-101:~# gluster volume heal staging-glusterfs full
Launching heal operation to perform full self heal on volume staging-glusterfs has been successful
Use heal info commands to check status
```

We can check the status by running:

```bash
root@ip-10-66-3-101:~# gluster volume heal staging-glusterfs info
 
Brick ip-10-66-3-101:/data/
/documents/2016-06-06
/documents/2016-06-06/28fb68ca-702f-4473-b707-fc86b59c81cf.pdf
/documents/2016-06-06/e4b255b8-981b-42ed-8259-7a101afff7ba.pdf
...
/documents/2016-06-06/973e6ac2-d1b5-4e9f-a9ea-d21158b1a754.pdf
/documents/2016-05-24
/documents/2016-05-20
/documents/2016-05-26
/documents/2016-05-27
/documents/2016-05-30
/documents/2016-05-31
/documents/2016-06-01
/documents/2016-06-02
/documents/2016-06-03
/documents/2016-05-25/f859021b-48ed-4110-bcab-712214ce8a40.pdf - Possibly undergoing heal
/documents/2016-05-25/fcb36670-7f36-49b6-bdb1-3868d7e579a8.pdf
/documents/2016-05-25/ff3f81ba-41b6-4bf9-8e48-12068061474c.pdf
Number of entries: 46
 
Brick ip-10-66-5-65:/data/
/documents/2016-06-06
/documents/2016-06-06/28fb68ca-702f-4473-b707-fc86b59c81cf.pdf
/documents/2016-06-06/e4b255b8-981b-42ed-8259-7a101afff7ba.pdf
...
/documents/2016-06-06/ef95567c-9b82-4d0a-9dd4-9447006567a3.pdf
/documents/2016-06-06/8e8b34e7-0b38-4f11-b9b4-d14b8ab753fc.pdf
/documents/2016-06-06/973e6ac2-d1b5-4e9f-a9ea-d21158b1a754.pdf
/documents/2016-05-20 - Possibly undergoing heal
/documents/2016-05-26
/documents/2016-05-27
/documents/2016-05-30
/documents/2016-05-31
/documents/2016-06-01
/documents/2016-06-02
/documents/2016-06-03
Number of entries: 42
 
Brick ip-10-66-4-238:/data/
Number of entries: 0
```

If we check again after some time:

```bash
root@ip-10-66-3-101:~# gluster volume heal staging-glusterfs info
 
Brick ip-10-66-3-101:/data/
Number of entries: 0
 
Brick ip-10-66-5-65:/data/
Number of entries: 0
 
Brick ip-10-66-4-238:/data/
Number of entries: 0
```

we can see the healing has finished and the cluster state is now:

```bash
root@ip-10-66-3-101:~# gluster volume info
Volume Name: staging-glusterfs
Type: Replicate
Volume ID: 2a0876ed-2988-46cb-8dea-98c25d092e36
Status: Started
Number of Bricks: 1 x 3 = 3
Transport-type: tcp
Bricks:
Brick1: 10.66.3.101:/data
Brick2: 10.66.5.65:/data
Brick3: 10.66.4.238:/data
Options Reconfigured:
network.ping-timeout: 5
cluster.quorum-type: auto
performance.cache-size: 256MB
cluster.server-quorum-type: server
 
root@ip-10-66-3-101:~# gluster volume status
Status of volume: staging-glusterfs
Gluster process                        Port    Online    Pid
------------------------------------------------------------------------------
Brick 10.66.3.101:/data                   49152    Y    26308
Brick 10.66.5.65:/data                    49152    Y    26095
Brick 10.66.4.238:/data                   49152    Y    2380
NFS Server on localhost                    2049    Y    11980
Self-heal Daemon on localhost               N/A    Y    11985
NFS Server on 10.66.4.238                  2049    Y    2391
Self-heal Daemon on 10.66.4.238             N/A    Y    2382
NFS Server on 10.66.5.65                   2049    Y    10909
Self-heal Daemon on 10.66.5.65              N/A    Y    10916
  
Task Status of Volume staging-glusterfs
------------------------------------------------------------------------------
There are no active volume tasks
```

But the disconnected node will still be showing in the peers list:

```bash
root@ip-10-66-3-101:~# gluster peer status
Number of Peers: 3
 
Hostname: ip-10-66-4-225.ap-southeast-2.compute.internal
Uuid: e4da23b0-0ffb-432c-b8ea-235067749109
State: Peer in Cluster (Disconnected)
Other names:
10.66.4.225
 
Hostname: 10.66.5.65
Uuid: d6773667-d6de-44c6-8ad9-71af21d5a367
State: Peer in Cluster (Connected)
 
Hostname: 10.66.4.238
Uuid: b5b9d91f-4943-4247-9b51-d2ecbc465b2b
State: Peer in Cluster (Connected)
```

We need to remove it manually:

```bash
root@ip-10-66-3-101:~# gluster peer detach 10.66.4.225
peer detach: success
  
root@ip-10-66-3-101:~# gluster peer status
Number of Peers: 2
 
Hostname: 10.66.5.65
Uuid: d6773667-d6de-44c6-8ad9-71af21d5a367
State: Peer in Cluster (Connected)
 
Hostname: 10.66.4.238
Uuid: b5b9d91f-4943-4247-9b51-d2ecbc465b2b
State: Peer in Cluster (Connected)
```

At the end we have to check `/etc/fstab` on the clients if the failed server was in their mount options and replace it with the new one we added. For example:

```
10.66.3.101:/staging-glusterfs /data glusterfs defaults,nobootwait,_netdev,backupvolfile-server=10.66.4.238,direct-io-mode=disable 0 0
```