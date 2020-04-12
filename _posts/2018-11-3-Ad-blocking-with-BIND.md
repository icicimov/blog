---
type: posts
header:
  teaser: 'images.jpg'
title: 'Ad blocking with BIND DNS'
categories: 
  - Server
tags: ['dns']
date: 2018-11-3
---

There are couple of options to block ads in Bind DNS server like ad block Zone files or RPZ (Response Policy Zones).

## Option 1: Zone file

Download the ad block zone file:

```bash
$ sudo wget -O /etc/bind/ad-blacklist 'http://pgl.yoyo.org/adservers/serverlist.php?hostformat=bindconfig&showintro=0&mimetype=plaintext'
```

The file looks like this:

```
// For more information about this list, see: https://pgl.yoyo.org/adservers/
// ----
// last updated:    Fri, 02 Nov 2018 01:40:19 GMT
// entries:         2925
// format:          bindconfig
// credits:         Peter Lowe - pgl@yoyo.org - https://pgl.yoyo.org/
// this URL:        http://pgl.yoyo.org/adservers/serverlist.php?hostformat=bindconfig&showintro=0&mimetype=plaintext
// other formats:   https://pgl.yoyo.org/adservers/formats.php

zone "101com.com" { type master; notify no; file "null.zone.file"; };
zone "101order.com" { type master; notify no; file "null.zone.file"; };
zone "123freeavatars.com" { type master; notify no; file "null.zone.file"; };
zone "180hits.de" { type master; notify no; file "null.zone.file"; };
...
```

We need to set full path to the zone file:

```bash
$ sudo vi /etc/bind/ad-blacklist
:%s/null/\/etc\/bind\/null/
:wq
```

We tell to use this localy new zonefile in `/etc/bind/named.conf.local`, I use split-horizon setup so only edit the internal view:

```bash
view internal {
   ...
   include "/etc/bind/ad-blacklist";
};
```

Next we create the actual zonefile `/etc/bind/null.zone.file` which looks like this:

```bash
$TTL    86400   ; one day  
@       IN      SOA     ads.example.com. hostmaster.example.com. (
               2014090101
                    28800
                     7200
                   864000
                    86400 )          
                NS      my.dns.server.org          
                A       0.0.0.0 
@       IN      A       0.0.0.0 
*       IN      A       0.0.0.0
```

Finally reload bind:

```bash
$ sudo rndc reload
```

Confirm it is working from a pc in the lan:

```
igorc@silverstone:~$ dig +short 101com.com
0.0.0.0
```

## Option 2: RPZ

Obtain zone file from producer:

```
$ sudo wget -O /var/cache/bind/internal/blacklist.icicimov.com.db https://raw.githubusercontent.com/oznu/dns-zone-blacklist/master/bind/bind-nxdomain.blacklist
```

Edit the Bind config in `/etc/bind/named.conf.local`, apply changes to the `internal` view only:

```bash
// example.com named.conf fragments relevant to RPZ
// stream the log to separate rpz info
logging{
...
    channel named-rpz {
       file "/var/log/named/rpz.log" versions 3 size 250k;
       severity info;
    };
    category rpz{
       named-rpz;
    };
...
};

...

view "internal" {
...
    // RPZ zone definition
    zone "blacklist.icicimov.com" {
        type master;
        file "internal/blacklist.icicimov.com.db";
    };
    // RPZ zone definition
    zone "whitelist.icicimov.com" {
        type master;
        file "internal/whitelist.icicimov.com.db";
    };
    // invoke RPZ
    response-policy {
        zone "whitelist.icicimov.com" policy PASSTHRU; // my own white list
        zone "blacklist.icicimov.com"; // obtained from producer
    };
...
};

...
```

and reload Bind service:

```bash
$ sudo rndc reload
```

Confirm it is working from a pc in the lan:

```bash
igorc@silverstone:~$ dig +noall +authority 101com.com
blacklist.icicimov.com.	60	IN	SOA	localhost. dns-zone-blacklist. 2 10800 3600 604800 3600
```