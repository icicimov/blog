---
type: posts
header:
  teaser: 'varnish.png'
title: 'Hghly Available Caching Cluster with Varnish and HAProxy in AWS'
categories: 
  - Server
tags: [varnish, caching, high-availability, cluster]
date: 2017-8-8
---

Varnish is a smart caching reverse-proxy and web application accelerator. According to its documentation Varnish Cache is really fast. It typically speeds up delivery with a factor of 300-1000x, depending on the architecture involved. In term of performance Varnish has been delivering up to 20 Gbps on regular off-the-shelf hardware. One of the key features of Varnish Cache, in addition to its performance, is the flexibility of its configuration language, VCL. VCL enables you to write policies on how incoming requests should be handled. In such a policy you can decide what content you want to serve, from where you want to get the content and how the request or response should be altered. And, you can [extend Varnish with modules (VMODs)](https://www.varnish-cache.org/vmods).

Varnish doesn't implement SSL/TLS and wants to dedicate all of its CPU cycles to what it does best. Varnish also implements HAProxy's PROXY protocol so that HAProxy can very easily be deployed in front of Varnish as an SSL offloader as well as a load balancer and pass it all relevant client information. Also, Varnish naturally supports decompression from the cache when a server has provided a compressed object, but doesn't compress however. HAProxy can then be used to compress outgoing data when backend servers do not implement compression, though it's rarely a good idea to compress on the load balancer unless the traffic is low.

Will be using Using Haproxy-1.7.8 (later updated to 1.7.9) and Varnish-5.1.1 (later updated to 5.1.3 to fix [DoS vulnerability](https://varnish-cache.org/security/VSV00001.html#vsv00001)) on Ubuntu-16.04 Xenial. The `t2.medium` is probably a good instance size to start with but we can upgrade in case of any issues like high cpu or memory usage or very low cache eviction times.

This is the servers layout across two AZs in AWS:

```
                                                   public
--------------+---------------------------+--------------
              |                           | 
          --------                    --------
          | HAP1 |                    | HAP2 |
          --------                    --------
    10.77.0.94|                 10.77.2.54|       private
-------+------+-----+-------------+-------+------+-------
       |            |             |              |
  ----------    ----------    ----------    ----------
  | CACHE1 |    |  APP1  |    | CACHE2 |    |  APP2  |
  ----------    ----------    ----------    ----------
  10.77.3.220   10.77.3.227   10.77.4.53    10.77.4.234
            AZ1                         AZ2
```

*ASCII digram of the cluster*

In this setup HAP forwards the static content requests to Varnish which in turn replies from cache or queries Tomcat for the content. Another option would be for Varnish to query Tomcat via HAP in case we need SSL connection to the APP servers too.

# HAProxy setup

HAProxy can make use of consistent URL hashing to intelligently distribute the load to the caching nodes and avoid cache duplication, resulting in a total cache size which is the sum of all caching nodes. Below are the Varnish related config changes to our standard HAP install in the `/etc/haproxy/haproxy.cfg` file:


```
[...]
frontend localhost
    bind *:80
    bind *:443 ssl crt /etc/haproxy/star_encompasshost_com.crt no-sslv3 ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:...
    mode http
    acl static_content path_end .jpg .gif .png .css .js .htm .html .ico .ttf .woff .eot .svg
    acl is_auth0 path -i -m str auth0
    acl is_api path -i -m str api
    acl varnish_available nbsrv(bk_varnish_uri) ge 1
    # Caches health detection + routing decision
    use_backend bk_varnish_uri if !is_auth0 !is_api varnish_available static_content
    default_backend tomcats
 
# static backend with balance based on the uri, including the query string
# to avoid caching an object on several caches
backend bk_varnish_uri
    mode http
    http-request set-header X-Forwarded-Port %[dst_port]
    http-request add-header X-Forwarded-Proto https if { ssl_fc }
    balance uri
    # Varnish must tell it's ready to accept traffic
    option httpchk HEAD /varnishcheck
    http-check expect status 200
    # client IP information
    option forwardfor except 127.0.0.0/8
    # avoid request redistribution when the number of caches changes (crash or start up)
    hash-type consistent
    server varnish1 10.77.3.220:6081 check maxconn 1000
    server varnish2 10.77.4.53:6081  check maxconn 1000
[...]
```

# Varnish setup

To install Varnish on Xenial:

```
# curl -L https://packagecloud.io/varnishcache/varnish5/gpgkey 2> /dev/null | apt-key add -
OK

# curl -sL 'https://packagecloud.io/install/repositories/varnishcache/varnish5/config_file.list?os=ubuntu&dist=xenial&source=script' 2> /dev/null > /etc/apt/sources.list.d/varnishcache_varnish5.list

# cat /etc/apt/sources.list.d/varnishcache_varnish5.list
# this file was generated by packagecloud.io for
# the repository at https://packagecloud.io/varnishcache/varnish5

deb https://packagecloud.io/varnishcache/varnish5/ubuntu/ xenial main
deb-src https://packagecloud.io/varnishcache/varnish5/ubuntu/ xenial main

# apt update
# apt list --upgradable
# apt install varnish -y
```

The main Varnish config file is `/etc/varnish/default.vcl`. The whole file I'm using can be downloaded from [here]({{ site.baseurl }}/download/default.vcl). It is based on the one you can find at [varnish-5.0-configuration-templates](https://github.com/mattiasgeniar/varnish-5.0-configuration-templates) on GitHub.

So basically we specify the backend for the tomcat servers, create a health check point that HAP will use to health-check Varnish and configure our caching rules. It's little bit intimidating but the in-line comments should help understanding what is going on and have in mind that the Varnish default subroutines still get appended to the ones we put in the `default.vcl` file. 

We'll just have a look below at the main part where we setup the backend and the way it is being called from the `vcl_init` subroutine.


```
backend bk_tomcats_1 {
    .host = "10.77.3.227";
    .port = "8080";
    .connect_timeout = 3s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
    .max_connections = 100;
    .probe = {
        #.url = "/haproxycheck";
        .request =
          "GET /encompass/healthcheck HTTP/1.1"
          "Host: domain.encompasshost.com"
          "Connection: close"
          "User-Agent: Varnish Health Probe";
        .expected_response = 200;
        .timeout = 1s;
        .interval = 5s;
        .window = 2;
        .threshold = 2;
        .initial = 2;
    }
}
 
backend bk_tomcats_2 {
    .host = "10.77.4.234";
    .port = "8080";
    .connect_timeout = 3s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
    .max_connections = 100;
    .probe = {
        #.url = "/haproxycheck";
        .request =
          "GET /encompass/healthcheck HTTP/1.1"
          "Host: domain.encompasshost.com"
          "Connection: close"
          "User-Agent: Varnish Health Probe";
        .expected_response = 200;
        .timeout = 1s;
        .interval = 5s;
        .window = 2;
        .threshold = 2;
        .initial = 2;
    }
}
 
sub vcl_init {
    # Called when VCL is loaded, before any requests pass through it.
    # Typically used to initialize VMODs.
 
    new vdir = directors.round_robin();
    vdir.add_backend(bk_tomcats_1);
    vdir.add_backend(bk_tomcats_2);
}

sub vcl_recv {
    set req.backend_hint = vdir.backend(); # send all traffic to the vdir director
[...]
}
```

The slightly modified Systemd service file `/lib/systemd/system/varnish.service` so varnish can listen on all interfaces:

```
[Unit]
Description=Varnish Cache, a high-performance HTTP accelerator
 
[Service]
Type=forking
 
# Maximum number of open files (for ulimit -n)
LimitNOFILE=131072
 
# Locked shared memory - should suffice to lock the shared memory log
# (varnishd -l argument)
# Default log size is 80MB vsl + 1M vsm + header -> 82MB
# unit is bytes
LimitMEMLOCK=85983232
 
# On systemd >= 228 enable this to avoid "fork failed" on reload.
#TasksMax=infinity
 
# Maximum size of the corefile.
LimitCORE=infinity
 
# Set WARMUP_TIME to force a delay in reload-vcl between vcl.load and vcl.use
# This is useful when backend probe definitions need some time before declaring
# configured backends healthy, to avoid routing traffic to a non-healthy backend.
#WARMUP_TIME=0
 
ExecStart=/usr/sbin/varnishd -a 0.0.0.0:6081 -T localhost:6082 -f /etc/varnish/default.vcl -S /etc/varnish/secret -s malloc,256m
ExecReload=/usr/share/varnish/reload-vcl
 
[Install]
WantedBy=multi-user.target
```

and we also create a Systemd drop-in file `/etc/systemd/system/varnish.service.d/10-custom.conf` (where we can set our modifications in the future without risking being overwritten by a package upgrade) which main purpose is to include the default SystemV config file that Sytemd ignores:

```
[Service]
TasksMax=infinity
EnvironmentFile=-/etc/default/varnish
```

Then start and enable the services:

```
# systemctl start varnish.service
# systemctl enable varnish.service
# systemctl start varnishncsa.service
# systemctl enable varnishncsa.service
```

where `varnish` is the main caching service and `varnishncsa` is the logging service. Some logs from haproxy showing the static content going to varnish servers:

```
Aug 06 13:19:00 ip-10-77-0-94 haproxy[5054]: xxx.xxx.xxx.xxx:61903 [06/Aug/2017:13:19:00.883] localhost~ bk_varnish_uri/varnish1 0/0/1/2/3 200 4614 - - ---- 6/6/0/0/0 0/0 "GET /favicon.ico HTTP/1.1"
Aug 06 13:19:37 ip-10-77-0-94 haproxy[5054]: xxx.xxx.xxx.xxx:62179 [06/Aug/2017:13:19:37.885] localhost~ bk_varnish_uri/varnish1 0/0/1/3/10 200 116558 - - ---- 2/2/0/0/0 0/0 "GET /dagre.js HTTP/1.1"
Aug 06 13:19:38 ip-10-77-0-94 haproxy[5054]: xxx.xxx.xxx.xxx:62180 [06/Aug/2017:13:19:38.301] localhost~ bk_varnish_uri/varnish2 0/0/1/1/5 200 113034 - - ---- 3/3/0/0/0 0/0 "GET /app.de4ffc939bbc0ec89c33.css HTTP/1.1"
Aug 06 13:20:39 ip-10-77-0-94 haproxy[5054]: xxx.xxx.xxx.xxx:62180 [06/Aug/2017:13:19:39.021] localhost~ bk_varnish_uri/varnish2 0/0/1/1/603 200 3038835 - - ---- 1/1/0/0/0 0/0 "GET /app.de4ffc939bbc0ec89c33.js HTTP/1.1"
Aug 06 13:20:46 ip-10-77-0-94 haproxy[5054]: xxx.xxx.xxx.xxx:62480 [06/Aug/2017:13:20:46.263] localhost~ bk_varnish_uri/varnish2 0/0/1/1/2 200 20465 - - ---- 6/6/0/0/0 0/0 "GET /ef3dd9e795c2124fcd2d6292b07543c9.png HTTP/1.1"
```

At the end some useful commands/tools that come with Varnish Cache installation (the first one helps monitoring hits and misses in realtime):

```
varnishncsa -F '%U%q %{Varnish:hitmiss}x'
varnishlog
varnishtop
varnishstat
```

# References

* [HAProxy, Varnish and the single hostname website](https://www.haproxy.com/blog/haproxy-varnish-and-the-single-hostname-website/)
* [Varnish Cache on GitHub](https://github.com/varnishcache/varnish-cache)