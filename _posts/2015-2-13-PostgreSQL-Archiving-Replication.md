---
type: posts
header:
  teaser: '42613560.jpeg'
title: 'PostgreSQL Archiving Replication'
category: Database
tags: [postgresql, replication, high-availability]
---

In this mode PostgreSQL replicates the WAL archive logs.

## Configuring the master server

First, create a new user in PostgreSQL, for replication purposes. We’ll use it to connect to the master instance from the slave and replicate data. To create the new user, execute:

```
$ sudo su - postgres psql -c "CREATE USER rep REPLICATION LOGIN CONNECTION LIMIT 1 ENCRYPTED PASSWORD 'password';"
```

The user created is called rep. Make sure to replace the word password with something better for production use.
Next we edit the master instance configuration files. Edit the pg_hba.conf file. It controls the client authentication for PostgreSQL. Add the line in below at the end of the file, using the real IP of the slave server. If we have it configured in the `/etc/hosts` file, we can add the hostname or an alias as well in `/etc/postgresql/9.3/main/pg_hba.conf`:

```
[...]
host replication rep <slave-IP>/32 md5
```

Then, edit the main PostgreSQL config file `/etc/postgresql/9.3/main/postgresql.conf` and set the following parameters:

```
listen_addresses = 'localhost,0.0.0.0'
wal_level = 'hot_standby'
archive_mode = on
archive_command = 'cd .'
max_wal_senders = 1
hot_standby = on
```

To apply the changes, restart PostgreSQL.

```
$ sudo service postgresql restart
```

## Configuring the slave server

Stop the service first:

```
$ sudo service postgresql stop
```

Edit the access permissions file by adding the following line at the end of `/etc/postgresql/9.3/main/pg_hba.conf`:

```
[...]
host replication rep <master-IP>/32 md5
```

Then in the `/etc/postgresql/9.3/main/postgresql.conf` file apply the following changes:

```
listen_addresses = 'localhost,0.0.0.0'
wal_level = 'hot_standby'
archive_mode = on
archive_command = 'cd .'
max_wal_senders = 1
hot_standby = on
Initial replication
```

Before the slave server can replicate from the master, it’s recommended to transfer the initial data structure. Go to the master server and dump a backup file:

```
$ sudo -u postgres psql -c "select pg_start_backup('initial_backup');"
```

Then, copy the dump to the slave server, except for the xlogs files:

```
$ rsync -cva --inplace --exclude=*pg_xlog* /var/lib/postgresql/9.3/main/ :/var/lib/postgresql/9.3/main/
$ sudo -u postgres psql -c "select pg_stop_backup();
```

The pg_stop_backup() command will do the backup cleanup.

Log in to the slave server again and configure a recovery file `/var/lib/postgresql/9.3/main/recovery.conf` with following content:

```
standby_mode = 'on'
primary_conninfo = 'host= port=5432 user=rep password=password'
trigger_file = '/tmp/postgresql.trigger.5432'
```

This file’s purpose is that later, if we create an (empty) `trigger_file` on the slave machine, the slave will reconfigure itself to act as a master.

To apply the changes, restart PostgreSQL in the slave server.

```
$ sudo service postgresql start
```

At this point the replication should be already working. If not, check the log file `/var/log/postgresql/postgresql-9.3-main.log` for more details.
