---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'File System sync with Csync2 and Lsyncd'
categories: 
  - DevOps
tags: [csync2,lsyncd,aws]
date: 2016-8-26
---

In this scenario we are migration from old 2.x to a new 3.0 Nexus instance in EC2 and we need to keep the new and old Nexus instances in sync until the migration is finally finished. Both instances are running Ubuntu-14.04.

## Csync2

First why do I prefer using Csync2 over simple Rsync? Rsync is quit good for one of sync jobs but when used in cronjob lets say every 5 minutes or every hour it can create high load and lots of traffic between the servers. It checks every file that exists on the node, compares the contents, size or last modification date and builds a list of files to be transferred based on that. And every time it needs to connect to each nodes. This is fine for occasional updates but we can see the problem for more regular ones with large number of files. Csync2 keeps a little database (sqlite as default) which contains the state of each file. This means that whenever it gets invoked, it first updates the database and only starts to connect to the nodes in case any files were added, modified or deleted. A massive win in the number of connections it needs to make to the nodes, as most of the time there won’t be any new files. And It’s also a lot faster in checking than a Rsync. Naturally the more nodes you have the more gains you’ll have in using csync especially in multi way sync cases like we need to keep 5 servers synced between each other. Plus it can automatically resolve sync conflicts (see below) which is a big advantage too.

In our case we will always be syncing from the old `nexus1` host to the new `nexus2` host. On both hosts:

```
$ sudo aptitude install librsync-dev libsqlite3-dev pkg-config libgnutls-dev flex bison build-essential
```

Csync2 is available from packages repo under Ubuntu but it's version 1.3.x. The source code is at version 2.0 and thats what I decided to install in this case.

```
$ wget http://oss.linbit.com/csync2/csync2-2.0.tar.gz
$ tar -xzf csync2-2.0.tar.gz
$ cd csync2-2.0
~/csync2-2.0$ ./configure
~/csync2-2.0$ make && sudo make install
```

When installing from source, csync2 sets up itself under `/usr/local/` instead the package default `/etc/` and `/var/lib/` hence we create symlinks for convenience:

```
$ sudo ln -s /usr/local/etc/csync2 /etc/csync2
$ sudo ln -s /usr/local/var/lib/csync2 /var/lib/csync2
$ sudo ldconfig
```

Next is the `/etc/csync2/csync2_nexus1.cfg` config file. On the source server:

```
lock-timeout 60;
#ignore uid;    # if the owner uid on the target differ from one on the source
#ignore gid;    # if the owner gid on the target differ from one on the source
#ignore mod;    # to ignore file perms when copying over
#nossl * *;     # use ssl or not
 
group nexus {
    host nexus1;
    host (nexus2);
    key /etc/csync2-nexus-group.key;
    include /opt/nexus;
    include /etc/init.d/nexus;
    include /opt/sonatype-work/nexus/storage;
    #include /opt/sonatype-work;
    #exclude /opt/sonatype-work/nexus/logs/;
 
    exclude *~ .*;
    exclude *.log;
    exclude *.pid;
 
    backup-directory /var/log/csync2/sync-conflicts/;
    backup-generations 2;
    auto first;
}
```

and on the target nexus2 side:

```
lock-timeout 60;
#ignore uid;    # if the owner uid on the target differ from one on the source
#ignore gid;    # if the owner gid on the target differ from one on the source
#ignore mod;    # to ignore file perms when copying over
#nossl * *;     # use ssl or not
 
group nexus {
    host (nexus2);
    host nexus1;
    key /etc/csync2-nexus-group.key;
    include /opt/nexus;
    include /etc/init.d/nexus;
    include /opt/sonatype-work/nexus/storage;
    #include /opt/sonatype-work;
    #exclude /opt/sonatype-work/nexus/logs/;
 
    exclude *~ .*;
    exclude *.log;
    exclude *.pid;
 
    backup-directory /var/log/csync2/sync-conflicts/;
    backup-generations 1;
    auto first;
}
```

By putting the nexus2 host inside brackets we tell Csync2 that this host will always be the sync target.

It is also possible to let Csync2 resolve conflicts automatically for some or all files using one of the pre-defined auto-resolve methods. The available methods are: none (the default behavior), first (the host on which Csync2 is executed first wins), younger and older (the younger or older file wins), bigger and smaller (the bigger or smaller file wins), left and right (the host on the left side or the right side in the host list wins). The younger, older, bigger and smaller methods let the remote side win the conflict if the file has been removed on the local side.

Since we want sync in one direction only, from nexus1 to nexus2, we use first here since Csync2 sync process will be only ever run on the nexus1 server to update the files on the nexus2 server.

Create the directory where we told Csync2 to store file conflicts (on both nodes):

```
$ sudo mkdir -p /var/log/csync2/sync-conflicts
```

Generate self-signed SSL certificates to encrypt the traffic on both servers, Csync2 looks for files named `csync2_ssl_key.pem` and `csync2_ssl_cert.pem` under its config dir so based on that we run:

```
$ sudo openssl req -x509 -newkey rsa:1024 -days 7200 -keyout /etc/csync2/csync2_ssl_key.pem -nodes -out /etc/csync2/csync2_ssl_cert.pem -subj '/CN=nexus'
```

Another way is to simply run:

```
~/csync2-2.0$ sudo make cert
```

inside the csync2 downloaded source directory on each host which will create and install the needed certificate `csync2_ssl_cert.pem` and the private key `csync2_ssl_key.pem` under `/usr/local/etc/`. The hosts will exchange the certs upon initial connection.

Next generate the pre-shared security key for the sync group:

```
$ sudo csync2 -k /etc/csync2/csync-nexus-group.key
$ sudo chmod 0600 /etc/csync2/csync-nexus-group.key
```

on one of the servers and copy it over to the other one.

### Setup Csync2 as network service

Another advantage of Csync2 is that it can run as a daemon via `Xinetd`. We should do this on the target(s) only in case we always sync in one direction. Do it on all host in case of bi-directional syncing. First add it to the services list in the `/etc/services` file:

```
[...]
# Local services
csync2          30865/tcp                       # Csync2 tcp port
```

next install `xinetd`:

```
$ sudo aptitude install -y xinetd
```

and configure it in the `/etc/xinetd.d/csync2` file we create:

```
service csync2
{
        disable         = no
        flags           = REUSE,IPv4
        socket_type     = stream
        port            = 30865
        protocol        = tcp
        user            = root
        wait            = no
        server          = /usr/local/sbin/csync2
        server_args     = -i -l  # add -N <hostname> here in case the hostname is different from the host in the csync2 config
        log_on_failure  += USERID
        only_from       = 52.xx.xx.xx/32 127.0.0.1
        per_source      = UNLIMITED
}
```

Restart xinetd and check if running:

```
$ sudo service xinetd restart
$ sudo netstat -tuplen | grep xinetd
tcp        0      0 0.0.0.0:30865           0.0.0.0:*               LISTEN      0          27097       15086/xinetd
```

Replace 52.xx.xx.xx/32 with the appropriate ElasticIP of the peer.

### Firewall

Open the TCP port 30865 in both EC2 Security Groups allowing traffic only from the correspondent peer instance.

### Run Csync2 for first time

Csync2 stores data in SQLite3 database(s) under `/usr/local/var/lib/csync2/` directory.

To scan the local system and create the initial database, run on both hosts:

```
$ sudo csync2 -C nexus1 -cIr /
```

The `-C nexus1` tells Csync2 to look for a config file name `csync2_nexus1.cfg` under its config dir, which is the name of the file we created on this node (nexus1) above.

Then on the master (nexus1 node) we do:

```
$ sudo csync2 -C nexus1 -TUIX
$ sudo csync2 -C nexus1 -udv   # to test (dry-run)
$ sudo csync2 -C nexus1 -uv    # real update
```

To run comparison only against the remote peer:

```
$ sudo csync2 -Tvvv
```

To test, dry run the real sync command:

```
$ sudo csync2 -C nexus1 -xvdr
```

Finally if all ok we can set this in crontab:

```
59 23 * * * csync2 -C nexus1 -xvr
```

to sync once daily.

It can happen that old data is left over in the Csync2 database after a configuration change (e.g.files and hosts which are not referred anymore by the configuration file). Running `csync2 -R` cleans up such old entries in the Csync2 database.

```
$ sudo csync2 -R
```

To get a list of all dirty files marked for synchronization run:

```
$ sudo csync2 -M
```

## Lsyncd for automation

Lsyncd helps automating the syncing process. It puts watcher on each `inode` via `inotify` and invokes Csync2 when ever it detects a file change. This turns the asynchronous replication process into close to synchronous. It only needs to run on the master (nexus1) node:

```
ubuntu@nexus1:~$ sudo aptitude install lsyncd
ubuntu@nexus1:~$ lsyncd --version
Version: 2.0.4
```

We create the following `/etc/[lsyncd.conf]({{ site.baseurl }}/download/lsyncd.conf)` Lua config file:

```
settings = {
        logident = "lsyncd",
        logfacility = "user",
        logfile = "/var/log/lsyncd/lsyncd.log",
        statusFile = "/var/log/lsyncd/status.log",
        statusInterval = 1
}
initSync = {
        delay = 1,
        maxProcesses = 1,
        action = function(inlet)
                local config = inlet.getConfig()
                local elist = inlet.getEvents(function(event)
                        return event.etype ~= "Blanket"
                end)
                local directory = string.sub(config.source, 1, -2)
                local paths = elist.getPaths(function(etype, path)
                        return "\t" .. config.syncid .. ":" .. directory .. path
                end)
                log("Normal", "Processing syncing list:\n", table.concat(paths, "\n"))
                spawn(elist, "/usr/local/sbin/csync2", "-C", config.syncid, "-xr")
        end,
        collect = function(agent, exitcode)
                local config = agent.config
                if not agent.isList and agent.etype == "Blanket" then
                        if exitcode == 0 then
                                log("Normal", "Startup of '", config.syncid, "' instance finished.")
                        elseif config.exitcodes and config.exitcodes[exitcode] == "again" then
                                log("Normal", "Retrying startup of '", config.syncid, "' instance.")
                                return "again"
                        else
                                log("Error", "Failure on startup of '", config.syncid, "' instance.")
                                terminate(-1)
                        end
                        return
                end
                local rc = config.exitcodes and config.exitcodes[exitcode]
                if rc == "die" then
                        return rc
                end
                if agent.isList then
                        if rc == "again" then
                                log("Normal", "Retrying events list on exitcode = ", exitcode)
                        else
                                log("Normal", "Finished events list = ", exitcode)
                        end
                else
                        if rc == "again" then
                                log("Normal", "Retrying ", agent.etype, " on ", agent.sourcePath, " = ", exitcode)
                        else
                                log("Normal", "Finished ", agent.etype, " on ", agent.sourcePath, " = ", exitcode)
                        end
                end
                return rc
        end,
        init = function(inlet)
                local config = inlet.getConfig()
                local event = inlet.createBlanketEvent()
                log("Normal", "Recursive startup sync: ", config.syncid, ":", config.source)
                spawn(event, "/usr/local/sbin/csync2", "-C", config.syncid, "-xr")
        end,
        prepare = function(config)
                if not config.syncid then
                        error("Missing 'syncid' parameter.", 4)
                end
                local c = "csync2_" .. config.syncid .. ".cfg"
                local f, err = io.open("/etc/csync2/" .. c, "r")
                if not f then
                        error("Invalid 'syncid' parameter: " .. err, 4)
                end
                f:close()
        end
}
local sources = {
        ["/opt/sonatype-work/nexus/storage"] = "nexus1"
}
for key, value in pairs(sources) do
        sync {initSync, source=key, syncid=value}
end
```

that tells Lsyncd what to monitor and how to invoke Csync2. The output and the operational stats will be saved under `/var/log/lsyncd`:

```
ubuntu@nexus1:~$ sudo mkdir -p /var/log/lsyncd
```

Increase the inotify limit before starting Lsyncd so we don't run out of watchers:

```
ubuntu@nexus1:~$ echo "fs.inotify.max_user_watches = 1048576" | sudo tee -a /etc/sysctl.conf
ubuntu@nexus1:~$ sudo sysctl -p
```

Test in foreground:

```
ubuntu@nexus1:~$ sudo lsyncd -nodaemon -log all /etc/lsyncd.conf
```

and to automate on startup we can add to the root user crontab:

```
@reboot keep-one-running /usr/bin/lsyncd -nodaemon -log all /etc/lsyncd.conf
```

To start as a service:

```
ubuntu@nexus1:~$ sudo service lsyncd start
```

We can see in the log files:

```
# /var/log/lsyncd/status.log
Lsyncd status report at Wed Aug  1 14:38:26 2016
Sync1 source=/opt/sonatype-work/nexus/storage/
There are 0 delays
Excluding:
  nothing.
Inotify watching 20676 directories
  1: /opt/sonatype-work/nexus/storage/
  2: /opt/sonatype-work/nexus/storage/morphia-googlecode/
  3: /opt/sonatype-work/nexus/storage/morphia-googlecode/.index/
  4: /opt/sonatype-work/nexus/storage/morphia-googlecode/com/
[...]
  20670: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/
  20671: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/
  20672: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/newrelic-api/
  20673: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/newrelic-api/3.2.3/
  20674: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/newrelic-api/3.12.1/
  20675: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/newrelic-api/3.18.0/
  20676: /opt/sonatype-work/nexus/storage/new-relic-release/.nexus/attributes/newrelic/java-agent/newrelic-api/2.7.0/
```

we are monitoring 20676 inodes and:

```
# /var/log/lsyncd/lsyncd.log
[...]
Wed Aug  1 14:38:24 2016 Normal: Processing syncing list:
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/tmp/discovery-status.txtnx-tmp7559478367286169804.nx-upload
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.meta/discovery-status.txt
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/tmp/discovery-status.txtnx-tmp4998107132572228453.nx-upload
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/attributes/.meta/discovery-status.txt
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/tmp/prefixes.txtnx-tmp7896834571075571418.nx-upload
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.meta/prefixes.txt
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/tmp/prefixes.txtnx-tmp2135745589265890880.nx-upload
        nexus1:/opt/sonatype-work/nexus/storage/michaelklishin/.nexus/attributes/.meta/prefixes.txt
[...]
```

syncing the file system to the remote node upon changes.

At the end, the following logrotate config `/etc/logrotate.d/lsyncd` will prevent the log files grow out of control:

```
/var/log/lsyncd/*.log {
    size 10M
    copytruncate
    rotate 7
    missingok
    notifempty
    compress
}
```
