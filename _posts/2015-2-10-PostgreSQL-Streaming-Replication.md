---
type: posts
title: 'PostgreSQL Streaming Replication'
category: Database
tags: [postgresql, replication, ha]
---

Streaming replication means the changes are synchronously applied from the master to the slave(s).

First, create the replication user on the master:

```
$ sudo -u postgres psql -c "CREATE USER replicator REPLICATION LOGIN ENCRYPTED PASSWORD '<replicator_password>';"
```

The user created is called replicator. Make sure to create strong password for production use.

Next, configure the master for streaming replication. Edit `/etc/postgresql/9.1/main/postgresql.conf` file:

```
[...]
listen_address = '*'
log_line_prefix='%t [%p] %u@%d '
wal_level = hot_standby
max_wal_senders = 3
checkpoint_segments = 8   
wal_keep_segments = 16
[...]
```

We're configuring 8 x WAL segments here, each is 16MB. Consider increasing those values if we expect our database to have more than 128MB of changes in the time it will take to make a copy of it across the network to our slave, or in the time we expect our slave to be down for maintenance.

Then edit the access control on the master to allow the connection from the slave in `/etc/postgresql/9.1/main/pg_hba.conf` file:

```
[...]
hostssl replication     replicator      <slave_ip>            md5
[...]
```

Restart the server for the changes to take effect:

```
$ sudo service postgresql restart
```

Now on to the slave. In the slave's `postgresql.conf` we add the following:

```
[...]
log_line_prefix='%t [%p] %u@%d '
wal_level = hot_standby
max_wal_senders = 3
checkpoint_segments = 8   
wal_keep_segments = 16
hot_standby = on
[...]
```

Then restart the slave. No changes are required in the slave's `pg_hba.conf` specifically to support replication. We'll still need to make whatever entries we need in order to connect to it from our application and run read-only queries, if we wish to have multiple db hosts read access. All writes should still go to the master only.

Then on the slave:

* Stop PostgreSQL

```
$ sudo service postgresql start
```

* Remove the database

```
$ sudo -u postgres rm -rf /var/lib/postgresql/9.1/main
```

* Start the base backup on the master to the slave as replicator user

```
$ sudo -u postgres pg_basebackup -h <master_ip> -D /var/lib/postgresql/9.1/main -U replicator -v -P
```

* Create recovery.conf file `/var/lib/postgresql/9.1/main/recovery.conf`
    
```
standby_mode = 'on'
primary_conninfo = 'host=<master_ip> port=5432 user=replicator password=<replicator_password> sslmode=require'
trigger_file = '/tmp/postgresql.trigger'
```

* Start PostgreSQL
  
```
$ sudo service postgresql start
```

After that we should see something like this in the slave log file:

```
user@slave:~$ sudo tail -f /var/log/postgresql/postgresql-9.1-main.log
LOG:  received smart shutdown request
LOG:  autovacuum launcher shutting down
LOG:  shutting down
LOG:  database system is shut down
LOG:  database system was interrupted; last known up at 2015-10-01 08:43:28 BST
LOG:  entering standby mode
LOG:  streaming replication successfully connected to primary
LOG:  redo starts at 0/66000020
LOG:  consistent recovery state reached at 0/66000688
LOG:  database system is ready to accept read only connections
```

and find PostgreSQL WAL processes running on both servers. On the master:

```
user@master:~$ ps ax -o pid,command | grep postgres | grep wal
27075 postgres: wal writer process                                                                                               
27934 postgres: wal sender process replicator <slave_ip>(19846) streaming 0/6719D650
```

and on the slave:

```
user@slave:~$ ps ax -o pid,command | grep postgres | grep wal
26357 postgres: wal receiver process   streaming 0/6719D650
```

We can notice the streaming numbers match. We can also check the xlog segments position to confirm they are same. On the master:

```
database=# SELECT pg_current_xlog_location();
 pg_current_xlog_location
--------------------------
 0/6713BEF8
(1 row)
```

and on the slave:

```
database=# select pg_last_xlog_replay_location();
 pg_last_xlog_replay_location
------------------------------
 0/6713BEF8
(1 row)
 
database=# select pg_last_xlog_receive_location();
 pg_last_xlog_receive_location
-------------------------------
 0/6713BEF8
(1 row)
```