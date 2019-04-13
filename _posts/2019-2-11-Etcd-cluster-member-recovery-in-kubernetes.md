---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Etcd cluster member recovery in Kubernetes'
categories: 
  - Kubernetes
tags: ['kubernetes','etcd']
date: 2019-2-21
---

This is a process I followed to recover one of the etcd masters that was broken after unsuccessful kops upgrade. Login to one of the healthy etcd cluster members:

```bash
$ export ETCD_POD=etcd-server-ip-10-99-7-49.eu-west-1.compute.internal

$ kubectl exec -it $ETCD_POD -n kube-system -- sh
/ # etcdctl member list
1e54307daa4a61d5: name=etcd-c peerURLs=http://etcd-c.internal.<cluster-name>:2380 clientURLs=http://etcd-c.internal.<cluster-name>:4001
52ffe075f64998e0: name=etcd-b peerURLs=http://etcd-b.internal.<cluster-name>:2380 clientURLs=http://etcd-b.internal.<cluster-name>:4001
6e166871eeab706e: name=etcd-a peerURLs=http://etcd-a.internal.<cluster-name>:2380 clientURLs=http://etcd-a.internal.<cluster-name>:4001
```

We will see warnings like this in this master log file:

```
2019-02-21 04:41:06.015572 W | rafthttp: the connection to peer 6e166871eeab706e is unhealthy
```

We remove the unhealthy member:

```bash
/ # etcdctl member remove 6e166871eeab706e
Removed member 6e166871eeab706e from cluster

/ # etcdctl member list
1e54307daa4a61d5: name=etcd-c peerURLs=http://etcd-c.internal.<cluster-name>:2380 clientURLs=http://etcd-c.internal.<cluster-name>:4001
52ffe075f64998e0: name=etcd-b peerURLs=http://etcd-b.internal.<cluster-name>:2380 clientURLs=http://etcd-b.internal.<cluster-name>:4001
```

and add it back again:

```bash
/ # etcdctl member add etcd-a http://etcd-a.internal.<cluster-name>:2380
Added member named etcd-a with ID ee2c106bbb99c710 to cluster

/ # etcdctl member list
1e54307daa4a61d5: name=etcd-c peerURLs=http://etcd-c.internal.<cluster-name>:2380 clientURLs=http://etcd-c.internal.<cluster-name>:4001
52ffe075f64998e0: name=etcd-b peerURLs=http://etcd-b.internal.<cluster-name>:2380 clientURLs=http://etcd-b.internal.<cluster-name>:4001
ee2c106bbb99c710[unstarted]: peerURLs=http://etcd-a.internal.<cluster-name>:2380
```

Kops has linked the etcd manifests to the persistent EBS volumes attached to the nodes: 

```bash
root@ip-10-99-6-149:~# ls -l /etc/kubernetes/manifests/etcd*
lrwxrwxrwx 1 root root 71 Feb 21 04:17 /etc/kubernetes/manifests/etcd-events.manifest -> /mnt/master-vol-019xxxxxxxxxxxxxx/k8s.io/manifests/etcd-events.manifest
lrwxrwxrwx 1 root root 64 Feb 21 04:53 /etc/kubernetes/manifests/etcd.manifest -> /mnt/master-vol-097yyyyyyyyyyyyyy/k8s.io/manifests/etcd.manifest
```

We need to remove the previous cluster data before we restart etcd on this master. If we check the /mnt/master-vol-097yyyyyyyyyyyyyy/k8s.io/manifests/etcd.manifest we can see that the data directory is mounted from /mnt/master-vol-097yyyyyyyyyyyyyy/var/etcd/data on the server so:

```bash
root@ip-10-99-6-149:~# rm -rf /mnt/master-vol-097yyyyyyyyyyyyyy/var/etcd/data/*
```

Then we set ETCD_INITIAL_CLUSTER_STATE variable in /mnt/master-vol-097yyyyyyyyyyyyyy/k8s.io/manifests/etcd.manifest from "new" to "existing" and wait for 
the pod to get restarted by kubernetes. We see this in the /var/log/etcd.log file:

```
2019-02-21 04:54:44.506606 I | flags: recognized and used environment variable ETCD_ADVERTISE_CLIENT_URLS=http://etcd-a.internal.<cluster-name>:4001
2019-02-21 04:54:44.506660 I | flags: recognized and used environment variable ETCD_DATA_DIR=/var/etcd/data
2019-02-21 04:54:44.506679 I | flags: recognized and used environment variable ETCD_INITIAL_ADVERTISE_PEER_URLS=http://etcd-a.internal.<cluster-name>:2380
2019-02-21 04:54:44.506697 I | flags: recognized and used environment variable ETCD_INITIAL_CLUSTER=etcd-a=http://etcd-a.internal.<cluster-name>:2380,etcd-b=http://etcd-b.internal.<cluster-name>:2380,etcd-c=http://etcd-c.internal.<cluster-name>:2380
2019-02-21 04:54:44.506704 I | flags: recognized and used environment variable ETCD_INITIAL_CLUSTER_STATE=new
2019-02-21 04:54:44.506743 I | flags: recognized and used environment variable ETCD_INITIAL_CLUSTER_TOKEN=etcd-cluster-token-etcd
2019-02-21 04:54:44.506767 I | flags: recognized and used environment variable ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:4001
2019-02-21 04:54:44.506786 I | flags: recognized and used environment variable ETCD_LISTEN_PEER_URLS=http://0.0.0.0:2380
2019-02-21 04:54:44.506810 I | flags: recognized and used environment variable ETCD_NAME=etcd-a
2019-02-21 04:54:44.506902 I | etcdmain: etcd Version: 2.2.1
2019-02-21 04:54:44.506921 I | etcdmain: Git SHA: 75f8282
2019-02-21 04:54:44.506925 I | etcdmain: Go Version: go1.5.1
2019-02-21 04:54:44.506929 I | etcdmain: Go OS/Arch: linux/amd64
2019-02-21 04:54:44.506936 I | etcdmain: setting maximum number of CPUs to 4, total number of available CPUs is 4
2019-02-21 04:54:44.506981 N | etcdmain: the server is already initialized as member before, starting as etcd member...
2019-02-21 04:54:44.507047 I | etcdmain: listening for peers on http://0.0.0.0:2380
2019-02-21 04:54:44.507076 I | etcdmain: listening for client requests on http://0.0.0.0:4001
2019-02-21 04:54:44.762947 I | etcdserver: recovered store from snapshot at index 374660949
2019-02-21 04:54:44.763000 I | etcdserver: name = etcd-a
2019-02-21 04:54:44.763005 I | etcdserver: data dir = /var/etcd/data
2019-02-21 04:54:44.763011 I | etcdserver: member dir = /var/etcd/data/member
2019-02-21 04:54:44.763017 I | etcdserver: heartbeat = 100ms
2019-02-21 04:54:44.763021 I | etcdserver: election = 1000ms
2019-02-21 04:54:44.763024 I | etcdserver: snapshot count = 10000
2019-02-21 04:54:44.763035 I | etcdserver: advertise client URLs = http://etcd-a.internal.<cluster-name>:4001
2019-02-21 04:54:44.763057 I | etcdserver: loaded cluster information from store: <nil>
2019-02-21 04:54:44.792670 I | etcdserver: restarting member ee2c106bbb99c710 in cluster 86f836eb6caa6aef at commit index 374669620
2019-02-21 04:54:44.793153 I | raft: ee2c106bbb99c710 became follower at term 480
2019-02-21 04:54:44.793178 I | raft: newRaft ee2c106bbb99c710 [peers: [1e54307daa4a61d5,52ffe075f64998e0,ee2c106bbb99c710], term: 480, commit: 374669620, applied: 374660949, lastindex: 374669620, lastterm: 480]
2019-02-21 04:54:44.802816 I | etcdserver: starting server... [version: 2.2.1, cluster version: 2.2]
2019-02-21 04:54:44.803497 I | rafthttp: the connection with 52ffe075f64998e0 became active
2019-02-21 04:54:44.803603 I | rafthttp: the connection with 1e54307daa4a61d5 became active
2019-02-21 04:54:44.803800 I | raft: raft.node: ee2c106bbb99c710 elected leader 52ffe075f64998e0 at term 480
2019-02-21 04:54:44.871008 I | etcdserver: published {Name:etcd-a ClientURLs:[http://etcd-a.internal.<cluster-name>:4001]} to cluster 86f836eb6caa6aef
2019-02-21 04:56:12.407414 I | etcdserver: start to snapshot (applied: 374670950, lastsnap: 374660949)
2019-02-21 04:56:12.531190 I | etcdserver: saved snapshot at index 374670950
2019-02-21 04:56:12.531358 I | etcdserver: compacted raft log at 374665950
```

The node finally joins the etcd cluster which we can confirm on the other other master node too: 

```bash
/ # etcdctl member list
1e54307daa4a61d5: name=etcd-c peerURLs=http://etcd-c.internal.<cluster-name>:2380 clientURLs=http://etcd-c.internal.<cluster-name>:4001
52ffe075f64998e0: name=etcd-b peerURLs=http://etcd-b.internal.<cluster-name>:2380 clientURLs=http://etcd-b.internal.<cluster-name>:4001
ee2c106bbb99c710: name=etcd-a peerURLs=http://etcd-a.internal.<cluster-name>:2380 clientURLs=http://etcd-a.internal.<cluster-name>:4001
```

## Repeat the same for the events cluster too

Unfortunately kops sets up separate cluster for the etcd events so we need to fix that one too :-/. Connect to one of the working etcd-server-events master pods and check the status:

```bash
/ # etcdctl -C http://127.0.0.1:4002 member list
3490d16d1046c85b: name=etcd-events-b peerURLs=http://etcd-events-b.internal.<cluster-name>:2381 clientURLs=http://etcd-events-b.internal.<cluster-name>:4002
5811b0ef10a0b424: name=etcd-events-a peerURLs=http://etcd-events-a.internal.<cluster-name>:2381 clientURLs=http://etcd-events-a.internal.<cluster-name>:4002
9f6724380259f2ca: name=etcd-events-c peerURLs=http://etcd-events-c.internal.<cluster-name>:2381 clientURLs=http://etcd-events-c.internal.<cluster-name>:4002
```

We can see the issue in this master's log:

```
2019-02-21 05:57:36.015376 W | rafthttp: the connection to peer 5811b0ef10a0b424 is unhealthy
2019-02-21 05:58:06.015572 W | rafthttp: the connection to peer 5811b0ef10a0b424 is unhealthy
```

Remove the faulty member and add it back:

```bash
/ # etcdctl -C http://127.0.0.1:4002 member remove 5811b0ef10a0b424
Removed member 5811b0ef10a0b424 from cluster

/ # etcdctl -C http://127.0.0.1:4002 member add etcd-events-a http://etcd-events-a.internal.<cluster-name>:2381
Added member named etcd-events-a with ID 94bb6350fbcd859 to cluster

/ # etcdctl -C http://127.0.0.1:4002 member list
94bb6350fbcd859[unstarted]: peerURLs=http://etcd-events-a.internal.<cluster-name>:2381
3490d16d1046c85b: name=etcd-events-b peerURLs=http://etcd-events-b.internal.<cluster-name>:2381 clientURLs=http://etcd-events-b.internal.<cluster-name>:4002
9f6724380259f2ca: name=etcd-events-c peerURLs=http://etcd-events-c.internal.<cluster-name>:2381 clientURLs=http://etcd-events-c.internal.<cluster-name>:4002
```

Then on the broken node we run:

```
root@ip-10-99-6-149:~# rm -rf /mnt/master-vol-019xxxxxxxxxxxxxx/data/* && \
                       rm -rf /mnt/master-vol-019xxxxxxxxxxxxxx/var/etcd/data-events/*
```

Then we set ETCD_INITIAL_CLUSTER_STATE variable in /mnt/master-vol-019xxxxxxxxxxxxxx/k8s.io/manifests/etcd-events.manifest from "new" to "existing" and wait for the pod to get restarted by kubelet. After that if we check on the master:

```bash
/ # etcdctl -C http://127.0.0.1:4002 member list
94bb6350fbcd859: name=etcd-events-a peerURLs=http://etcd-events-a.internal.<cluster-name>:2381 clientURLs=http://etcd-events-a.internal.<cluster-name>:4002
3490d16d1046c85b: name=etcd-events-b peerURLs=http://etcd-events-b.internal.<cluster-name>:2381 clientURLs=http://etcd-events-b.internal.<cluster-name>:4002
9f6724380259f2ca: name=etcd-events-c peerURLs=http://etcd-events-c.internal.<cluster-name>:2381 clientURLs=http://etcd-events-c.internal.<cluster-name>:4002
```

all is back in order and the quorum is established.