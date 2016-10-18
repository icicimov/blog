---
type: posts
header:
  teaser: 'Logstash_central_log_server_architecture.png'
title: 'Securing Logstash to Redis communication with Stunnel'
categories: 
  - Monitoring
  - Logging
tags: [logstash, redis, stunnel]
---

Logstash is meant for private LAN usage since it doesn't offer any kind of encryption support. If we need to ship sensitive data across WAN's, like between Amazon VPC's, we would like to have the communication channel secure. That's where `Stunnel` comes in play.

## Stunnel installation and configuration

Stunnel provides SSL/TLS encryption to applications lacking this feature. We are going to run stunnel server on the central Redis server each Logstash client connects to and stunnel client on each of the clients. For added security stunnel will run jailed in chroot.

### Server side setup

First we install `stunnel4` and enable the service for start up:

```
root@server:~# aptitude install stunnel4
root@server:~# vi /etc/default/stunnel4
ENABLED=1
...
```

Then we create a stunnel configuration file `/etc/stunnel/redis-server.conf`:

```
debug = 7
output = /stunnel.log
compression = zlib
sslVersion = TLSv1
options = NO_SSLv2
cert = /etc/stunnel/stunnel.pem
client = no
pid = /stunnel.pid
chroot = /var/lib/stunnel4/
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
 
[redis]
accept = 10.1.16.1:6379
connect = 127.0.0.1:6379
```

We are going to jail the process in `/var/lib/stunnel4/` so first we need to create some files for the chroot environment:

```
root@server:~# mkdir /var/lib/stunnel4/etc
root@server:~# cp /etc/hosts.allow /etc/hosts.deny /var/lib/stunnel4/etc
```

We need a SSL certificate so we create a self-signed one and set appropriate permissions for the files:

```
root@server:~# openssl genrsa -out /etc/stunnel/key.pem 4096
root@server:~# openssl req -x509 -new -nodes -key /etc/stunnel/key.pem -out /etc/stunnel/cert.pem -subj '/C=AU/ST=NSW/O=Mys Corporation/OU=IT/CN=server.mydomain.com' -days 7300
root@server:~# cat /etc/stunnel/key.pem /etc/stunnel/cert.pem > /etc/stunnel/stunnel.pem
root@server:~# chmod 0640 /etc/stunnel/key.pem /etc/stunnel/cert.pem /etc/stunnel/stunnel.pem
```

At the end we start the service and enable the auto start on reboot:

```
root@server:~# /etc/init.d/stunnel4 start
root@server:~# update-rc.d stunnel4 enable
```

We can check the log file under `/var/lib/stunnel4/` (since that's the jailed process root file system) for any errors. At the end we adjust the stunnel4 logs path in the logrotate script to the new jail path `/etc/logrotate.d/stunnel4`:

```
/var/lib/stunnel4/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 stunnel4 stunnel4
    sharedscripts
    postrotate
        /etc/init.d/stunnel4 reopen-logs > /dev/null
    endscript
}
```

### Client side setup

On the client side we go through the same process of installation:

```
root@client:~# aptitude install stunnel4
root@client:~# vi /etc/default/stunnel4
```

but the config file `/etc/stunnel/redis-client.conf` we create is slightly different:

``` 
debug = 7
output = /stunnel.log
compression = zlib
sslVersion = TLSv1
options = NO_SSLv2
cert = /etc/stunnel/stunnel.pem
client = yes
pid = /stunnel.pid
chroot = /var/lib/stunnel4/
setuid = stunnel4
setgid = stunnel4
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
 
[redis]
accept = 127.0.0.1:6379
connect = <server-EIP>:6379
```

We then transfer the certificate we created on the server to the client at `/etc/stunnel/stunnel.pem` and set its permissions:

```
root@client:~# chmod 0640 /etc/stunnel/stunnel.pem
```

We are going to jail the process in `/var/lib/stunnel4/` on the client as well so first we need to create some files for the chroot environment:

```
root@server:~# mkdir /var/lib/stunnel4/etc
root@server:~# cp /etc/hosts.allow /etc/hosts.deny /var/lib/stunnel4/etc
```

Finally we start the service and enable the auto start:

```
root@client:~# /etc/init.d/stunnel4 start
root@client:~# update-rc.d stunnel4 enable
```

At the end we adjust the stunnel4 logs path in the logrotate script to the new jail path as given for the server part above.

With all this setup, the Logstash client now will connect to its local stunnel process at `127.0.0.1:6379` which will encrypt the data and send it to its peer listening on the remote Redis server `<server-EIP>` tcp port `6379`. There, stunnel will decrypt the data and hand it over to the local Redis server in plain text.

### Redis and Logstash

Now Redis should only listen on the local interface `127.0.0.1` and will be remotely accessible only via stunnel's SSL. In the Logstash configuration on the client side we point the process to also write to the local ip 127.0.0.1 where the local stunnel process is listening.
