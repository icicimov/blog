---
type: posts
header:
  teaser: 'mongodb.png'
title: 'MongoDB Replica Set setup'
categories: 
  - Database
tags: ['database', 'mongodb', 'aws'] 
date: 2013-05-15
---

The replica set will consist of 3 nodes (given with their host names) created and hosted in Amazon EC2: ip-172-31-16-61 (PRIMARY), ip-172-31-16-62 (SECONDARY) and ip-172-31-16-21 (ARBITER). The nodes are created from Ubuntu-12.04 AWS AMI.

## MongoDB installation and configuration

First prepare the storage on the PRIMARY and SECONDARY nodes:

```
$ sudo pvcreate /dev/xvde
$ sudo vgcreate vg_mongodb /dev/xvde
$ sudo lvcreate --name lv_mongodb -l 100%vg vg_mongodb
$ sudo mkfs -f -t xfs -L MONGODB /dev/vg_mongodb/lv_mongodb
```

And adjust the `readahead` for the volumes as recommended by MongoDB:

```
$ sudo vi /etc/udev/rules.d/85-ebs.rules
ACTION=="add", KERNEL=="xvde", ATTR{bdi/read_ahead_kb}="16"
```

Then prepare the mount point:

```
$ sudo vi /etc/fstab
[...]
# MongoDB v3.0 LVM
LABEL=MONGODB /var/lib/mongodb xfs noauto,noatime,noexec,nodiratime 0 0
```

and mount the volume:

```
$ sudo mount -L MONGODB 
$ sudo chown -R mongodb\: /var/lib/mongodb
```

Then we need to install MongoDB on each of the nodes listed above:

```
$ sudo apt-key adv --keyserver keyserver.ubuntu.com --recv 7F0CEB10
$ echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' | sudo tee /etc/apt/sources.list.d/10gen.list
$ sudo aptitude update
$ sudo aptitude install mongodb-10gen=2.2.2
```

The configuration of the MongoDB instance in the `/etc/mongodb.conf` file on each of the nodes is given bellow :

```
dbpath=/var/lib/mongodb
logpath=/var/log/mongodb/mongodb.log
logappend=true
auth=true
replSet=mongo_replica_set
rest=true
keyFile=/etc/mongo_keyfile
```

We want user authentication enabled and also the cluster members to authenticate to each other via the secret key. We also set the Replica Set name in this file.

## Firewall

Open the appropriate ports in the Security Group the DB instances have been assigned in the VPC. All 3 servers should be able to connect to each other on port 27017.

## Replica set configuration

We want to configure the replica set with one Master, one Secondary and one Arbiter node.

* Turn off authentication in the config file and restart mongo on all (future) cluster members

Change `auth=true` to `noauth=true` and restart the MongoDB instances.

* Create replica set key file

```
$ dd status=noxfer if=/dev/random bs=1 count=200 2>/dev/null | tr -dc 'a-z0-9A-Z' | tr 'A-Z' 'a-z' | sudo tee /etc/mongo_keyfile
ydrfmoelvedhfcvtefazt8jalo6dkwvpxty4d0gkhepw0hwo8jj
$ sudo chown mongodb:mongodb /etc/mongo_keyfile
$ sudo chmod 0600 /etc/mongo_keyfile
```

* Start the MongoDB instances on all of the nodes and make sure they are running and can connect to each other on port 27017

* On the ip-172-31-16-61 (we want it to be MASTER) do:

```
$ mongo
> rs.initiate()
{
    "info2" : "no configuration explicitly specified -- making one",
    "me" : "ip-172-31-16-61:27017",
    "info" : "Config now saved locally.  Should come online in about a minute.",
    "ok" : 1
}
> rs.conf()
{
    "_id" : "mongo_replica_set",
    "version" : 1,
    "members" : [
        {
            "_id" : 0,
            "host" : "ip-172-31-16-61:27017"
        }
    ]
}
> mongo_replica_set:PRIMARY> rs.status()
{
    "set" : "mongo_replica_set",
    "date" : ISODate("2013-05-09T01:52:56Z"),
    "myState" : 1,
    "members" : [
        {
            "_id" : 0,
            "name" : "ip-172-31-16-61:27017",
            "health" : 1,
            "state" : 1,
            "stateStr" : "PRIMARY",
            "uptime" : 1777,
            "optime" : Timestamp(1368064029000, 1),
            "optimeDate" : ISODate("2013-05-09T01:47:09Z"),
            "self" : true
        }
    ],
    "ok" : 1
}
> mongo_replica_set:PRIMARY> rs.add( { "_id": 1, "host": "ip-172-31-16-62:27017", "priority": 0.5 } );
{ "ok" : 1 }
mongo_replica_set:PRIMARY> rs.status()
{
    "set" : "mongo_replica_set",
    "date" : ISODate("2013-05-09T04:00:19Z"),
    "myState" : 1,
    "members" : [
        {
            "_id" : 0,
            "name" : "ip-172-31-16-61:27017",
            "health" : 1,
            "state" : 1,
            "stateStr" : "PRIMARY",
            "uptime" : 9420,
            "optime" : Timestamp(1368071940000, 1),
            "optimeDate" : ISODate("2013-05-09T03:59:00Z"),
            "self" : true
        },
        {
            "_id" : 1,
            "name" : "ip-172-31-16-62:27017",
            "health" : 1,
            "state" : 5,
            "stateStr" : "STARTUP2",
            "uptime" : 79,
            "optime" : Timestamp(0, 0),
            "optimeDate" : ISODate("1970-01-01T00:00:00Z"),
            "lastHeartbeat" : ISODate("2013-05-09T04:00:19Z"),
            "pingMs" : 476
        }
    ],
    "ok" : 1
}
mongo_replica_set:PRIMARY> rs.add( { "_id": 2, "host": "ip-172-31-16-21:27017", "priority": 0, "arbiterOnly" : true } );
{ "ok" : 1 }
mongo_replica_set:PRIMARY> rs.status()
{
    "set" : "mongo_replica_set",
    "date" : ISODate("2013-05-09T04:04:36Z"),
    "myState" : 1,
    "members" : [
        {
            "_id" : 0,
            "name" : "ip-172-31-16-61:27017",
            "health" : 1,
            "state" : 1,
            "stateStr" : "PRIMARY",
            "uptime" : 9677,
            "optime" : Timestamp(1368072248000, 1),
            "optimeDate" : ISODate("2013-05-09T04:04:08Z"),
            "self" : true
        },
        {
            "_id" : 1,
            "name" : "ip-172-31-16-62:27017",
            "health" : 1,
            "state" : 2,
            "stateStr" : "SECONDARY",
            "uptime" : 336,
            "optime" : Timestamp(1368072248000, 1),
            "optimeDate" : ISODate("2013-05-09T04:04:08Z"),
            "lastHeartbeat" : ISODate("2013-05-09T04:04:36Z"),
            "pingMs" : 0
        },
        {
            "_id" : 2,
            "name" : "ip-172-31-16-21:27017",
            "health" : 1,
            "state" : 7,
            "stateStr" : "ARBITER",
            "uptime" : 28,
            "lastHeartbeat" : ISODate("2013-05-09T04:04:35Z"),
            "pingMs" : 6
        }
    ],
    "ok" : 1
}
```

The nodes have now been synchronized and the replica has been setup.

* While still in `noauth` mode create the database instances and users

* Revert back to `auth` mode in `mongodb.conf` file and restart all the instances

* Expanding the replica set

I have added a new MongoDB instance in the second Zone of the AWS VPC with host name ip-172-31-10-61. Started the database on the new node and added it to the cluster:

```
root@ip-172-31-16-61:~# mongo
MongoDB shell version: 2.2.2
connecting to: test
> use admin
switched to db admin
> db.auth('admin','my-admin-password');
1
mongo_replica_set:PRIMARY> rs.status()
{
    "set" : "mongo_replica_set",
    "date" : ISODate("2013-05-14T08:38:53Z"),
    "myState" : 1,
    "members" : [
        {
            "_id" : 0,
            "name" : "ip-172-31-16-61:27017",
            "health" : 1,
            "state" : 1,
            "stateStr" : "PRIMARY",
            "uptime" : 1130452,
            "optime" : Timestamp(1371964671000, 1),
            "optimeDate" : ISODate("2013-06-23T05:17:51Z"),
            "self" : true
        },
        {
            "_id" : 1,
            "name" : "ip-172-31-16-62:27017",
            "health" : 1,
            "state" : 2,
            "stateStr" : "SECONDARY",
            "uptime" : 1130451,
            "optime" : Timestamp(1371964671000, 1),
            "optimeDate" : ISODate("2013-06-23T05:17:51Z"),
            "lastHeartbeat" : ISODate("2013-05-14T08:38:51Z"),
            "pingMs" : 0
        },
        {
            "_id" : 2,
            "name" : "ip-172-31-16-21:27017",
            "health" : 1,
            "state" : 7,
            "stateStr" : "ARBITER",
            "uptime" : 1130451,
            "lastHeartbeat" : ISODate("2013-05-14T08:38:51Z"),
            "pingMs" : 0
        }
    ],
    "ok" : 1
}
mongo_replica_set:PRIMARY> rs.add( { "_id": 3, "host": "ip-172-31-10-61:27017", "priority": 0.25 } );
{ "ok" : 1 }
mongo_replica_set:PRIMARY> rs.status()
{
    "set" : "mongo_replica_set",
    "date" : ISODate("2013-05-14T08:45:02Z"),
    "myState" : 1,
    "members" : [
        {
            "_id" : 0,
            "name" : "ip-172-31-16-61:27017",
            "health" : 1,
            "state" : 1,
            "stateStr" : "PRIMARY",
            "uptime" : 1130821,
            "optime" : Timestamp(1372063263000, 1),
            "optimeDate" : ISODate("2013-05-14T08:41:03Z"),
            "self" : true
        },
        {
            "_id" : 1,
            "name" : "ip-172-31-16-62:27017",
            "health" : 1,
            "state" : 2,
            "stateStr" : "SECONDARY",
            "uptime" : 1130820,
            "optime" : Timestamp(1372063263000, 1),
            "optimeDate" : ISODate("2013-05-14T08:41:03Z"),
            "lastHeartbeat" : ISODate("2013-05-14T08:45:01Z"),
            "pingMs" : 0
        },
        {
            "_id" : 2,
            "name" : "ip-172-31-16-21:27017",
            "health" : 1,
            "state" : 7,
            "stateStr" : "ARBITER",
            "uptime" : 1130820,
            "lastHeartbeat" : ISODate("2013-05-14T08:45:01Z"),
            "pingMs" : 17
        },
        {
            "_id" : 3,
            "name" : "ip-172-31-10-61:27017",
            "health" : 1,
            "state" : 5,
            "stateStr" : "STARTUP2",
            "uptime" : 239,
            "optime" : Timestamp(0, 0),
            "optimeDate" : ISODate("1970-01-01T00:00:00Z"),
            "lastHeartbeat" : ISODate("2013-05-14T08:45:02Z"),
            "pingMs" : 1
        }
    ],
    "ok" : 1
}
mongo_replica_set:PRIMARY>
```

The new member instantly accepted the role of Secondary and started syncing the data. The member in the second zone has been added with priority of 0.25 since we want it to have lower chance of becoming Primary then the Secondary in the first zone which has priority of 0.5.