---
type: posts
header:
  teaser: 'word-image.png'
title: 'HAProxy Load Balancer with sticky sessions'
categories: 
  - DevOps
tags: ['haproxy'] 
date: 2015-12-30
---

HAProxy is highly customizable and function reach software load balancer. The below section outlines the installation and configuration of HAProxy as https load balancer with sticky sessions in front of two application servers in AWS hosted VPC.

## Setup

Install via ppa:

```bash
$ sudo add-apt-repository ppa:gwibber-daily/ppa
$ sudo aptitude install  haproxy=1.5-dev18-0ubuntu1~precise
```

Create self signed x.509 (PEM encoded) certificate for the LBs:

```bash
$ openssl genrsa 1024 > ec2CaKey.pem
$ openssl req -key ec2CaKey.pem -new -out ec2CaCsr.pem -subj '/C=AU/ST=NSW/L=Sydney/O=Portland Risk Analytics Pty Ltd/CN=*.mydomain.com' -days 7300
$ openssl x509 -req -days 7300 -in ec2CaCsr.pem -signkey ec2CaKey.pem -out ec2CaCert.pem
$ cat ec2CaCert.pem ec2CaKey.pem > ec2.mydomain.com.crt
```

Upload the `ec2.mydomain.com.crt` file into `/etc/haproxy/` directory on the LBs.

Create the haproxy logs directory:

```bash
root@haproxy:~# mkdir /var/log/haproxy/
```

and then setup the rsyslog to redirect haproxy output to separate file:

```bash
root@haproxy:~# vi /etc/rsyslog.d/49-haproxy.conf
if ($programname == 'haproxy') then -/var/log/haproxy/haproxy.log
& ~
```

Finally, we take care of the log rotation and maintenance via logrotate, file `/etc/logrotate.d/haproxy`:

```bash
/var/log/haproxy/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 syslog adm
    sharedscripts
    postrotate
       /etc/init.d/haproxy reload > /dev/null
    endscript
}
```

To start the service we run:

```bash
$ sudo /usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -D -p /var/run/haproxy.pid
```

or using the LSB script under `/etc/init.d/haproxy` so we can start/stop as service:

```bash
$ sudo service haproxy start
$ sudo service haproxy stop
```

## Session persistence with LB cookies

We cerate the basic configuration in `/etc/haproxy/haproxy.cfg` file:

```bash
global
    log /dev/log local7
    maxconn 4096
    user root
    group root
    daemon
    debug
    stats socket /tmp/haproxy
 
defaults
    log     global
    mode    http
    option  socket-stats
    option  httplog
    option  dontlognull
    option  logasap
    option  log-separate-errors 
    option  http-server-close
    retries 3
    maxconn 2000
    timeout connect 21s
    timeout client  60m
    timeout server  60m
    timeout check   60s
    timeout queue   60s
    timeout http-keep-alive 15
 
frontend http-in
    bind *:80
    redirect scheme https if !{ ssl_fc }
 
listen https-in
    bind    *:443 ssl crt /etc/haproxy/star_encompasshost_com.crt
    balance leastconn
    option  persist
    option  redispatch
    option  forwardfor except 127.0.0.1 header X-Forwarded-For
    option  httpchk GET /resource/hc/application HTTP/1.1\r\nHost:\ myhost.mydomain.com

    reqadd X-Forwarded-Proto:\ https if is-ssl

    cookie SERVERID insert indirect nocache maxidle 30m maxlife 8h
    server ip-10-22-1-18 10.22.1.18:443 ssl maxconn 200 cookie ip-10-22-1-18 check inter 2s
    server ip-10-22-2-34 10.22.2.34:443 ssl maxconn 200 cookie ip-10-22-2-34 check inter 2s
```

The above configuration translates into:

* redirect http traffic to https
* use /resource/hc/application path for backend health check in 2 seconds intervals
* insert `SERVERID` persistent cookie with value of the backend server name upon initial connection
* stick the consecutive requests coming from same session (SERVERID cookie) to same backend
* but redispatch the session to the other server if that one is down
* disable cookie caching and set max idle (30 minutes) and life (8 hours) time for the cookie 
* establish maximum of 200 concurrent client connections per backend server
* enable UNIX socket statistics

This option is very convenient for setting up Highly-Available HAProxy cluster of servers behind DNS record since the `SERVERID` cookie injected by the LB is stored on the client side (browser).

## Session persistence with stick tables

In this case we use the `JSESSIONID` cookie from the backend server for session persistence. The stripped down setup looks like this:

```
[...]
peers LB
    peer ip-10-22-2-110 10.22.2.110:34181
    peer ip-10-22-1-175 10.22.1.175:34181

frontend http-in
    bind *:80
    bind *:443 ssl crt /etc/haproxy/star_encompasshost_com.crt
    redirect scheme https if !{ ssl_fc }
    default_backend tomcats

backend tomcats
    [...]
    stick-table type string len 32 size 30k expire 60m peers LB
    stick store-response res.cook(JSESSIONID)
    stick on req.cook(JSESSIONID)
    tcp-request content track-sc0 req.cook(JSESSIONID)
    [...]
```

So each server will create a stick-table per backend proxy and replicate the state to its peers via port 34181, which we need to make sure is opened in the firewall. We can check the sessions state from each server's socket stats:

```bash
root@ip-10-22-2-110:~# echo "show table tomcats" | sudo socat stdio /run/haproxy/admin.sock
# table: tomcats, type: string, size:30720, used:10
0x8465f4: key=04939656BF230A8B1A26C70E996AEC86 use=0 exp=3396805 server_id=1
0x7c3734: key=58B7757A43F3F765B0F8D611552C5C9A use=0 exp=2896857 server_id=2
0x7c3674: key=6BB161FC7E591D3A190CE929F841558D use=0 exp=924255 server_id=2
0x7c38b4: key=7CFBC91693588E9E83500281BA8FFC3D use=0 exp=2896807 server_id=2
0x847144: key=97E4D9167B2CA59D2723E7E9D9EB44C1 use=0 exp=2947527 server_id=2
0x7fc3c4: key=B5A18026E0E5BD25B252454E30196936 use=0 exp=3384273 server_id=1
0x7c3974: key=C9F0F45C2E9559D34654E4DC61DBB566 use=0 exp=2896776 server_id=2
0x7c37f4: key=DC90E2FADD1D8BC06C69AA57CFE86DF8 use=0 exp=3384225 server_id=2
0x7f03a4: key=DF22C8B03BF880B154C2665D7EF33066 use=0 exp=2896785 server_id=2
0x7ee384: key=F29695A61B28EB06FF21E66D88F909C8 use=0 exp=3384230 server_id=2
 
root@ip-10-22-1-175:~# echo "show table tomcats" | sudo socat stdio /run/haproxy/admin.sock
# table: tomcats, type: string, size:30720, used:10
0x846334: key=04939656BF230A8B1A26C70E996AEC86 use=0 exp=3387872 server_id=1
0x7dac84: key=58B7757A43F3F765B0F8D611552C5C9A use=0 exp=2887924 server_id=2
0x84c104: key=6BB161FC7E591D3A190CE929F841558D use=0 exp=2938594 server_id=2
0x850a74: key=7CFBC91693588E9E83500281BA8FFC3D use=0 exp=2887874 server_id=2
0x850bf4: key=97E4D9167B2CA59D2723E7E9D9EB44C1 use=0 exp=2938594 server_id=2
0x882984: key=B5A18026E0E5BD25B252454E30196936 use=0 exp=3375339 server_id=1
0x850b34: key=C9F0F45C2E9559D34654E4DC61DBB566 use=0 exp=2887844 server_id=2
0x7db074: key=DC90E2FADD1D8BC06C69AA57CFE86DF8 use=0 exp=3375292 server_id=2
0x850964: key=DF22C8B03BF880B154C2665D7EF33066 use=0 exp=2887853 server_id=2
0x7d7024: key=F29695A61B28EB06FF21E66D88F909C8 use=0 exp=3375296 server_id=2
```

We can see there are the same 10 entries in each server's stick-table confirming the replication works between the peers. From the logs we can confirm the sessions sticking to the same server:

```
Dec 30 00:46:55 ip-10-22-1-175 haproxy[1938]: <MY_IP>:48362 [30/Dec/2015:00:46:50.094] localhost~ tomcats/10.22.2.34 376/0/0/5391/5774 200 30548 - JSESSIONID=58B7757A43F3F765B0F8D611552C5C9A.ip-10-22-2-34 ---- 10/10/0/1/0 0/0 "GET /myapi/dataproduct/prices HTTP/1.1"
Dec 30 00:47:12 ip-10-22-1-175 haproxy[1938]: <MY_IP>:48376 [30/Dec/2015:00:47:11.614] localhost~ tomcats/10.22.2.34 394/0/0/308/711 200 20916 JSESSIONID=58B7757A43F3F765B0F8D611552C5C9A.ip-10-22-2-34 - ---- 2/2/0/1/0 0/0 "GET /myapi/workspace/58B7757A HTTP/1.1"
Dec 30 00:47:13 ip-10-22-1-175 haproxy[1938]: <MY_IP>:48377 [30/Dec/2015:00:47:11.833] localhost~ tomcats/10.22.2.34 1674/0/0/85/1759 200 2061 JSESSIONID=58B7757A43F3F765B0F8D611552C5C9A.ip-10-22-2-34 - ---- 2/2/1/2/0 0/0 "GET /myapi/workspace/58B7757A/documents HTTP/1.1"
Dec 30 00:47:13 ip-10-22-1-175 haproxy[1938]: <MY_IP>:48376 [30/Dec/2015:00:47:12.325] localhost~ tomcats/10.22.2.34 1179/0/1/162/1342 202 542 JSESSIONID=58B7757A43F3F765B0F8D611552C5C9A.ip-10-22-2-34 - ---- 2/2/0/1/0 0/0 "GET /myapi/workspace/58B7757A/orders/statusCounts HTTP/1.1"
Dec 30 00:47:13 ip-10-22-1-175 haproxy[1938]: <MY_IP>:48376 [30/Dec/2015:00:47:12.325] localhost~ tomcats/10.22.2.34 1179/0/1/162/1342 202 542 JSESSIONID=58B7757A43F3F765B0F8D611552C5C9A.ip-10-22-2-34 - ---- 4/4/0/1/0 0/0 "GET /myapi/user/preferences/search HTTP/1.1"
```

The advantage of this approach is that the requests without session id like the static content are being served by any of the backend servers since they are not persisted. In the previous case HAP inserts cookie for every response independently from the backend session cookies. The disadvantage is though that the state of the stick-table is not saved upon restart.

## Statistics page and administration

For the end, about using the stats on the UNIX socket we enabled in the configuration.

```bash
root@haproxy:~# aptitude install socat
 
root@haproxy:~# echo "show info;show stat" | socat stdio unix-connect:/tmp/haproxy
Name: HAProxy
Version: 1.5-dev18
Release_date: 2013/04/03
Nbproc: 1
Process_num: 1
Pid: 3968
Uptime: 35d 2h22m47s
Uptime_sec: 3032567
Memmax_MB: 0
Ulimit-n: 8228
Maxsock: 8228
Maxconn: 4096
Hard_maxconn: 4096
Maxpipes: 0
CurrConns: 59
PipesUsed: 0
PipesFree: 0
ConnRate: 0
ConnRateLimit: 0
MaxConnRate: 99
CompressBpsIn: 0
CompressBpsOut: 0
CompressBpsRateLim: 0
ZlibMemUsage: 0
MaxZlibMemUsage: 0
Tasks: 68
Run_queue: 1
Idle_pct: 98
node: haproxy
```

If the permissions on the socket are elevated to admin level as in this example:

```
global
...
    stats socket /tmp/haproxy level admin
...
```

then we can perform admin tasks on the balancer like disabling a backend for example:

```bash
$ echo "disable server https-in/ip-172-31-42-41" | sudo socat stdio /tmp/haproxy
```

This will put it in `MAINTENANCE` state while we perform some work on it and when done we can enable it again.