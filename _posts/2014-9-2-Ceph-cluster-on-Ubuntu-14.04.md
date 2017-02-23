---
type: posts
header:
  teaser: 'Ceph_Logo.png'
title: 'Ceph cluster on Ubuntu-14.04'
categories: 
  - Storage
tags: [high-availability, cluster, ceph]
date: 2014-9-2
---

As pointed on its home page, [Ceph](https://ceph.com/) is a unified, distributed storage system designed for performance, reliability and scalability. It provides seamless access to objects using native language bindings or radosgw (RGW), a REST interface that's compatible with applications written for S3 and Swift. Ceph's RADOS Block Device (RBD) provides access to block device images that are striped and replicated across the entire storage cluster. It also provides a POSIX-compliant network file system (CephFS) that aims for high performance, large data storage, and maximum compatibility with legacy.

I'm setting up a ceph cluster on three VM's ostack-ceph1, ostack-ceph2 and ostack-ceph3, using the first one as deployment node as well.

First we make sure the nodes can resolve each other names, we add to `/etc/hosts` on each server:

```
192.168.122.211 ostack-ceph1.virtual.local  ostack-ceph1
192.168.122.212 ostack-ceph2.virtual.local  ostack-ceph2
192.168.122.213 ostack-ceph3.virtual.local  ostack-ceph3
```

Then setup a password-less login for my user from ostack-ceph1 to ostack-ceph2 and ostack-ceph3. Create ssh public-private key pair:

```
igorc@ostack-ceph1:~$ ssh-keygen -t rsa -f /home/igorc/.ssh/id_rsa -N ''
```

and copy the public key over to the other nodes:

```
igorc@ostack-ceph1:~$ cat /home/igorc/.ssh/id_rsa.pub | ssh igorc@ostack-ceph2 "cat >> ~/.ssh/authorized_keys"
igorc@ostack-ceph1:~$ cat /home/igorc/.ssh/id_rsa.pub | ssh igorc@ostack-ceph3 "cat >> ~/.ssh/authorized_keys"
igorc@ostack-ceph1:~$ ssh igorc@ostack-ceph2 "chmod 600 ~/.ssh/authorized_keys"
igorc@ostack-ceph1:~$ ssh igorc@ostack-ceph3 "chmod 600 ~/.ssh/authorized_keys"
```

Next set:

```
%sudo	ALL=(ALL:ALL) NOPASSWD:ALL
```

in `/etc/sudoers` file on each server. Make sure the user is part of the `sudo` group on each node.

```
$ sudo usermod -a -G sudo igorc
```

Then we can install `ceph-deploy` on ostak-ceph1:

```
igorc@ostack-ceph1:~$ wget -q -O- 'https://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/release.asc' | sudo apt-key add -
igorc@ostack-ceph1:~$ echo deb http://ceph.com/debian-dumpling/ $(lsb_release -sc) main | sudo tee /etc/apt/sources.list.d/ceph.list
igorc@ostack-ceph1:~$ sudo aptitude update && sudo aptitude install ceph-deploy
```

Now we can prepare the deployment directory, install ceph on all nodes and initiate the cluster:

```
igorc@ostack-ceph1:~$ mkdir ceph-cluster && cd ceph-cluster
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy install ostack-ceph1 ostack-ceph2 ostack-ceph3
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy --cluster ceph new ostack-ceph{1,2,3}
```

Then I modify the `ceph.conf` file as shown below:

```
igorc@ostack-ceph1:~/ceph-cluster$ vi ceph.conf 
[global]
fsid = ed8d8819-e05b-48d4-ba9f-f0bc8493f18f
mon_initial_members = ostack-ceph1, ostack-ceph2, ostack-ceph3
mon_host = 192.168.122.211, 192.168.122.212, 192.168.122.213
auth_cluster_required = cephx
auth_service_required = cephx
auth_client_required = cephx
filestore_xattr_use_omap = true
public_network = 192.168.122.0/24

[mon.ostack-ceph1]
     host = ostack-ceph1 
     mon addr = 192.168.122.211:6789

[mon.ostack-ceph2]
     host = ostack-ceph2 
     mon addr = 192.168.122.212:6789

[mon.ostack-ceph3]
     host = ostack-ceph3 
     mon addr = 192.168.122.213:6789

# added below config
[osd]
osd_journal_size = 512 
osd_pool_default_size = 3
osd_pool_default_min_size = 1
osd_pool_default_pg_num = 64 
osd_pool_default_pgp_num = 64
```

and continue with Monitors installation:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy mon create ostack-ceph1 ostack-ceph2 ostack-ceph3
```

Also collect the admin keyring on the local node and set read permissions:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy gatherkeys ostack-ceph1
igorc@ostack-ceph1:~/ceph-cluster$ sudo chmod +r /etc/ceph/ceph.client.admin.keyring
```

Now we can check the quorum status of the cluster:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph quorum_status --format json-pretty

{ "election_epoch": 6,
  "quorum": [
        0,
        1,
        2],
  "quorum_names": [
        "ostack-ceph1",
        "ostack-ceph2",
        "ostack-ceph3"],
  "quorum_leader_name": "ostack-ceph1",
  "monmap": { "epoch": 1,
      "fsid": "ed8d8819-e05b-48d4-ba9f-f0bc8493f18f",
      "modified": "0.000000",
      "created": "0.000000",
      "mons": [
            { "rank": 0,
              "name": "ostack-ceph1",
              "addr": "192.168.122.211:6789\/0"},
            { "rank": 1,
              "name": "ostack-ceph2",
              "addr": "192.168.122.212:6789\/0"},
            { "rank": 2,
              "name": "ostack-ceph3",
              "addr": "192.168.122.213:6789\/0"}]}}
```

We also deploy the MDS component on all 3 nodes for redundancy:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy --overwrite-conf mds create ostack-ceph1 ostack-ceph2 ostack-ceph3
```

Next we set-up the OSD's:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy --overwrite-conf osd --zap-disk create ostack-ceph1:/dev/sda ostack-ceph2:/dev/sda ostack-ceph3:/dev/sda
```

after which we can create our first pool:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph osd pool create datastore 100
pool 'datastore' created
```

The number of placement groups (pgp) is based on `100 x the number of OSD’s / the number of replicas we want to maintain`. I want 3 copies of the data (so if a server fails no data is lost), so `3 x 100 / 3 = 100`. 

Since I want to use this cluster as backend storage for Openstack Cinder and Glance I need to create some users with permissions to access specific pools. First is the `client.datastore` user for Cinder with access to the `datastore` pool we just created. We need to create a keyring, add it to ceph and set the appropriate permissions for the user on the pool:

```
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool --create-keyring /etc/ceph/ceph.client.datastore.keyring
igorc@ostack-ceph1:~/ceph-cluster$ sudo chmod +r /etc/ceph/ceph.client.datastore.keyring
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool /etc/ceph/ceph.client.datastore.keyring -n client.datastore --gen-key
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool -n client.datastore --cap mon 'allow r' --cap osd 'allow class-read object_prefix rbd_children, allow rwx pool=datastore' /etc/ceph/ceph.client.datastore.keyring
igorc@ostack-ceph1:~/ceph-cluster$ ceph auth add client.datastore -i /etc/ceph/ceph.client.datastore.keyring
```

Now, we add the `client.datastore` user settings to the `ceph.conf` file:

```
...
[client.datastore]
     keyring = /etc/ceph/ceph.client.datastore.keyring
```

and push that to all cluster members:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy --overwrite-conf config push ostack-ceph1 ostack-ceph2 ostack-ceph3
```

Since we have MON service running on each host we want to be able to mount from each host too so we need to copy the new key we created:

```
igorc@ostack-ceph1:~/ceph-cluster$ scp /etc/ceph/ceph.client.datastore.keyring ostack-ceph2:~ && ssh ostack-ceph2 sudo cp ceph.client.datastore.keyring /etc/ceph/  
igorc@ostack-ceph1:~/ceph-cluster$ scp /etc/ceph/ceph.client.datastore.keyring ostack-ceph3:~ && ssh ostack-ceph3 sudo cp ceph.client.datastore.keyring /etc/ceph/
```

We repeat the same procedure for Glance user and pool:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph osd pool create images 64
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool --create-keyring /etc/ceph/ceph.client.images.keyring
igorc@ostack-ceph1:~/ceph-cluster$ sudo chmod +r /etc/ceph/ceph.client.images.keyring
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool /etc/ceph/ceph.client.images.keyring -n client.images --gen-key
igorc@ostack-ceph1:~/ceph-cluster$ sudo ceph-authtool -n client.images --cap mon 'allow r' --cap osd 'allow class-read object_prefix rbd_children, allow rwx pool=images' /etc/ceph/ceph.client.images.keyring 
igorc@ostack-ceph1:~/ceph-cluster$ ceph auth add client.images -i /etc/ceph/ceph.client.images.keyring 
```

Now, we add the `client.images` user settings to the `ceph.conf` file:

```
...
[client.images]
     keyring = /etc/ceph/ceph.client.images.keyring
```

 and push that to all cluster members:

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph-deploy --overwrite-conf config push ostack-ceph1 ostack-ceph2 ostack-ceph3
```

As previously done we need to copy the new key we created to all nodes:

```
igorc@ostack-ceph1:~/ceph-cluster$ scp /etc/ceph/ceph.client.images.keyring ostack-ceph2:~ && ssh ostack-ceph2 sudo cp ceph.client.images.keyring /etc/ceph/
igorc@ostack-ceph1:~/ceph-cluster$ scp /etc/ceph/ceph.client.images.keyring ostack-ceph3:~ && ssh ostack-ceph3 sudo cp ceph.client.images.keyring /etc/ceph/
```

**UPDATE: 25/08/2015**

The `ceph fs new` command was introduced in Ceph 0.84. Prior to this release, no manual steps are required to create a file system, and pools named `data` and `metadata` exist by default. The Ceph command line now includes commands for creating and removing file systems, but at present only one file system may exist at a time.

```
igorc@ostack-ceph1:~/ceph-cluster$ ceph osd pool create cephfs_metadata 64
igorc@ostack-ceph1:~/ceph-cluster$ ceph osd pool create cephfs_data 64
igorc@ostack-ceph1:~/ceph-cluster$ ceph fs new cephfs cephfs_metadata cephfs_data
new fs with metadata pool 2 and data pool 1

igorc@ostack-ceph1:~/ceph-cluster$ ceph osd lspools
0 rbd,1 cephfs_data,2 cephfs_metadata,3 datastore,4 images,

igorc@ostack-ceph1:~/ceph-cluster$ ceph fs ls
name: cephfs, metadata pool: cephfs_metadata, data pools: [cephfs_data ]

igorc@ostack-ceph1:~/ceph-cluster$ ceph mds stat
e5: 1/1/1 up {0=ostack-ceph1=up:active}

igorc@ostack-ceph1:~/ceph-cluster$ ceph status
    cluster 5f1b2264-ab6d-43c3-af6c-3062e707a623
     health HEALTH_WARN
            too many PGs per OSD (320 > max 300)
     monmap e1: 3 mons at {ostack-ceph1=192.168.122.211:6789/0,ostack-ceph2=192.168.122.212:6789/0,ostack-ceph3=192.168.122.213:6789/0}
            election epoch 4, quorum 0,1,2 ostack-ceph1,ostack-ceph2,ostack-ceph3
     mdsmap e5: 1/1/1 up {0=ostack-ceph1=up:active}
     osdmap e25: 3 osds: 3 up, 3 in
      pgmap v114: 320 pgs, 5 pools, 1962 bytes data, 20 objects
            107 MB used, 22899 MB / 23006 MB avail
                 320 active+clean

igorc@ostack-ceph1:~/ceph-cluster$ ceph osd tree
ID WEIGHT  TYPE NAME             UP/DOWN REWEIGHT PRIMARY-AFFINITY 
-1 0.02998 root default                                            
-2 0.00999     host ostack-ceph1                                   
 0 0.00999         osd.0              up  1.00000          1.00000 
-3 0.00999     host ostack-ceph2                                   
 1 0.00999         osd.1              up  1.00000          1.00000 
-4 0.00999     host ostack-ceph3                                   
 2 0.00999         osd.2              up  1.00000          1.00000
```