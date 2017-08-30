---
type: posts
header:
  teaser: 'apache-traffic-server.jpg'
title: 'Apache Traffic Server as Caching Reverse Proxy'
categories: 
  - Server
tags: ['trafficserver', caching']
date: 2017-7-16
excerpt: "[Apache Traffic Server](http://trafficserver.apache.org/) is a high-performance web proxy cache that improves network efficiency and performance by caching frequently-accessed information at the edge of the network. This brings content physically closer to end users, while enabling faster delivery and reduced bandwidth use. Traffic Server is designed to improve content delivery"
---
{% include toc %}
# Introduction

[Apache Traffic Server](http://trafficserver.apache.org/) is a high-performance web proxy cache that improves network efficiency and performance by caching frequently-accessed information at the edge of the network. This brings content physically closer to end users, while enabling faster delivery and reduced bandwidth use. Traffic Server is designed to improve content delivery for enterprises, Internet service providers (ISPs), backbone providers, and large intranets by maximizing existing and available bandwidth.

Formerly a commercial product, Yahoo! donated it to the Apache Foundation, and it is now an Apache TLP. TS is typically used to serve static content, such as images, JavaScript, CSS, HTML files, and route requests for dynamic content to a web (origin) server. It is fast, flexible, proven and reliable, used by major service providers in the world like Yahoo! and LinkedIn to serve thousands of GB's per day.

Main features:

* Caching - disk and in memory caching for the most frequently accsessed objects
* Proxying - both forward and reverse proxy with websockets support
* Speed - scales well on modern SMP hardware, handling 10s of thousands of requests per second
* Plugins - about 20 stable ones and much more in experimental state
* Extensible - APIs to write custom plug-ins to do anything from modifying HTTP headers to handling ESI requests to writing custom cache algorithm
* Proven - handling over 400TB a day at Yahoo! (as per their 2009 report) both as forward and reverse proxies
* Secure - built-in support for SSL and OCSP stapling
* Clustering - built-in support for cluster of caches

Traffic Server contains three processes that work together to serve requests and manage, control, and monitor the health of the system.

* traffic_server - the transaction processing engine of Traffic Server, it is responsible for accepting connections, processing protocol requests, and serving documents from the cache or origin server.
* traffic_manager - the command and control facility of the Traffic Server, responsible for launching, monitoring, and reconfiguring the `traffic_server` process. If the `traffic_manager` process detects a `traffic_server` process failure, it instantly restarts the process but also maintains a connection queue of all incoming requests. All incoming connections that arrive in the several seconds before full server restart are saved in the connection queue and processed in first-come, first-served order. This connection queueing shields users from any server restart downtime.
* traffic_cop - monitors the health of both the `traffic_server` and `traffic_manager` processes. The `traffic_cop` process periodically (several times each minute) queries the `traffic_server` and `traffic_manager` processes by issuing heartbeat requests to fetch synthetic web pages. In the event of failure (if no response is received within a timeout interval or if an incorrect response is received), `traffic_cop` restarts the `traffic_manager` and `traffic_server` processes.

# Setup

An EC2 m3.medium or t2.medium instance type is good enough for this purpose. I have used Ubuntu-16.04 (Xenial) for OS.

## Installation

Starting by installing the needed packages:

```
$ sudo apt install automake libtool pkg-config libmodule-install-perl gcc g++ \
libssl-dev tcl-dev libpcre3-dev libcap-dev libhwloc-dev libncurses5-dev \
libcurl4-openssl-dev flex autotools-dev bison debhelper dh-apparmor gettext \
intltool-debian libbison-dev libexpat1-dev libfl-dev libsigsegv2 libsqlite3-dev \
m4 po-debconf tcl8.6-dev zlib1g-dev
```

and then download, compile and install the latest stable version of ATS:

```
$ wget http://apache.melbourneitmirror.net/trafficserver/trafficserver-7.1.0.tar.bz2
$ tar -xjf trafficserver-7.1.0.tar.bz2
$ cd trafficserver-7.1.0
$ ./configure
$ make && sudo make install
```

The content of the ATS's config directory after install:

```
$ ls -l /usr/local/etc/trafficserver/
total 152
drwxr-xr-x 3 nobody nogroup  4096 Jul 16 01:28 body_factory
-rw-r--r-- 1 nobody nogroup  1794 Jul 16 01:28 cache.config
-rw-r--r-- 1 nobody nogroup   657 Jul 16 01:28 cluster.config
-rw-r--r-- 1 nobody nogroup  1982 Jul 16 01:28 congestion.config
-rw-r--r-- 1 nobody nogroup   875 Jul 16 01:28 hosting.config
-rw-r--r-- 1 nobody nogroup  1288 Jul 16 01:28 ip_allow.config
-rw-r--r-- 1 nobody nogroup  6234 Jul 16 01:28 logging.config
-rw-r--r-- 1 nobody nogroup   440 Jul 16 01:28 log_hosts.config
-rw-r--r-- 1 nobody nogroup 54820 Jul 16 01:28 metrics.config
-rw-r--r-- 1 nobody nogroup  1499 Jul 16 01:28 parent.config
-rw-r--r-- 1 nobody nogroup   393 Jul 16 01:28 plugin.config
-rw-r--r-- 1 nobody nogroup 11217 Jul 16 01:28 records.config
-rw-r--r-- 1 nobody nogroup  8847 Jul 16 01:28 remap.config
-rw-r--r-- 1 nobody nogroup  677  Jul 16 01:28 socks.config
-rw-r--r-- 1 nobody nogroup  2251 Jul 16 01:28 splitdns.config
-rw-r--r-- 1 nobody nogroup  2872 Jul 16 01:28 ssl_multicert.config
-rw-r--r-- 1 nobody nogroup  1893 Jul 16 01:28 storage.config
-rw-r--r-- 1 root   root       19 Jul 16 01:28 trafficserver-release
-rw-r--r-- 1 nobody nogroup   649 Jul 16 01:28 vaddrs.config
-rw-r--r-- 1 nobody nogroup  1403 Jul 16 01:28 volume.config
```

Create symlink for convenience:

```
$ sudo ln -s /usr/local/etc/trafficserver /etc/trafficserver
```

and create the directory that will host the SSL files:

```
$ sudo mkdir /etc/trafficserver/ssl
$ sudo chown nobody /etc/trafficserver/ssl
$ sudo chmod 0760 /etc/trafficserver/ssl
```

The Systemd unit file in case we want to run as service:

```
[Unit]
Description=Apache Traffic Server
After=network.service systemd-networkd.service network-online.target dnsmasq.service
 
[Service]
Type=simple
ExecStart=/usr/bin/traffic_cop
ExecReload=/usr/bin/traffic_ctl config reload
Restart=always
RestartSec=1
 
LimitNOFILE=1000000
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
TasksMax=30000
PrivateTmp=yes
 
CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_IPC_LOCK CAP_KILL
CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID
SystemCallFilter=~acct modify_ldt add_key adjtimex clock_adjtime
delete_module fanotify_init finit_module get_mempolicy init_module
io_destroy io_getevents iopl ioperm io_setup io_submit io_cancel kcmp
kexec_load keyctl lookup_dcookie mbind migrate_pages mount move_pages
open_by_handle_at perf_event_open pivot_root process_vm_readv
process_vm_writev ptrace remap_file_pages request_key set_mempolicy
swapoff swapon umount2 uselib vmsplice
 
ReadOnlyDirectories=/etc
ReadOnlyDirectories=/usr
ReadOnlyDirectories=/var/lib
ReadWriteDirectories=/etc/trafficserver/internal
ReadWriteDirectories=/etc/trafficserver/snapshots
 
[Install]
WantedBy=multi-user.target
Enable Reverse Proxying
```

Within the `records.config` configuration file (the TS main config file), ensure that the following settings have been configured as shown below:

```
CONFIG proxy.config.http.cache.http INT 1
CONFIG proxy.config.reverse_proxy.enabled INT 1
CONFIG proxy.config.url_remap.remap_required INT 1
CONFIG proxy.config.url_remap.pristine_host_hdr INT 0
CONFIG proxy.config.http.server_ports STRING 8080 443:ssl
```

which enables the caching and the reverse proxy and also the ports the service will listen on for http and https traffic.

The `proxy.config.url_remap.remap_required` setting requires that a remap rule exist before Traffic Server will proxy the request and ensures that our proxy cannot be used to access the content of arbitrary websites (allowing someone of malicious intent to potentially mask their identity to an unknown third party).

The `proxy.config.url_remap.pristine_host_hdr` setting causes Traffic Server to keep the Host: client request header intact which is necessary in cases where the origin servers may be performing domain-based virtual hosting, or taking other actions dependent upon the contents of that header. We set this to zero for reverse proxy.

## Mappings

This is where the proxy to the backend origin server(s) is specified. The `remap.config` file is used for this purpose:

```
map https://proxy.encompasshost.com/cache/ https://{cache} @action=allow @src_ip=<office-ip> @src_ip=<another-office-ip>

redirect http://proxy.encompasshost.com/ https://proxy.encompasshost.com/ 
map https://proxy.encompasshost.com/ https://origin.encompasshost.com/
reverse_map https://origin.encompasshost.com/ https://proxy.encompasshost.com/
 
map / https://origin.encompasshost.com/
```

This is where we define which incoming domain name maps to which origin domain/server. We can see that there has been a reverse proxy set for `proxy.encompasshost.com` domain name; if we use domain name different to the one at the origin we need to rewrite (remap) all the origin URLs to that one. If the domain names are same we don't need to do anything and the TS server can act as forwarding caching proxy in which case we need to disable the below parameters by setting their value to zero:

```
CONFIG proxy.config.reverse_proxy.enabled INT 0
CONFIG proxy.config.url_remap.remap_required INT 0
CONFIG proxy.config.url_remap.pristine_host_hdr INT 1
```

The last line is a catch-all statement that prevents the server from being used as open relay by malicious third party i.e. proxying their requests through our TS server in order to hide their real source identity.

## Caching

The following config enables the caching and set some useful settings like ignoring client no-cache request:

```
CONFIG proxy.config.http.cache.http INT 1
CONFIG proxy.config.http.cache.ignore_client_cc_max_age INT 1
CONFIG proxy.config.http.normalize_ae_gzip INT 1
CONFIG proxy.config.http.cache.cache_responses_to_cookies INT 1
CONFIG proxy.config.http.cache.cache_urls_that_look_dynamic INT 1
CONFIG proxy.config.http.cache.when_to_revalidate INT 0
CONFIG proxy.config.http.cache.required_headers INT 2
CONFIG proxy.config.http.cache.ignore_client_no_cache INT 1
```

The `proxy.config.http.cache.ignore_client_no_cache` setting enables us to ignore the client no-cache requests and serve the content from cache if present.

The `proxy.config.http.cache.ignore_client_cc_max_age` setting enables TS to ignore any `Cache-Control: max-age` headers from the client.

The `proxy.config.http.normalize_ae_gzip` setting enables TS to normalize all `Accept-Encoding: headers` to one of the following:

* Accept-Encoding: gzip (if the header has gzip or x-gzip with any q) OR
* blank (for any header that does not include gzip)

This is useful for minimizing cached alternates of documents (e.g. gzip,deflate vs. deflate,gzip).

### Storage Sizing and Partitioning

We configure this in the `storage.config` file:


```
var/trafficserver 2048M
```

I've given the cache 2GB of disk space here. Further more, TS provides an option to partition the storage into volumes that can be used for different domains lets say. We do this in the `volume.config` file if needed, for example this splits the storage into 4 volumes each having 25% of the available size:

```
volume=1 scheme=http size=25%
volume=2 scheme=http size=25%
volume=3 scheme=http size=25%
volume=4 scheme=http size=25%
```

and then we can specify how we want to use the volumes which is done in the `hosting.config` file:

```
hosting.config
domain=origin.encompasshost.com volume=1,2,3,4
hostname=* volume=1,2,3,4
```

Since we have a single domain/host in this case all volumes are dedicated to it. It is still useful since it introduces parallelism to the cache reads and writes and an opportunity to easily separate the caches for various domains in the future.

### Memory Cache Sizing

By default the RAM cache size is automatically determined, based on disk cache size; approximately 10 MB of RAM cache per GB of disk cache. The `proxy.config.cache.ram_cache.size` parameter can be used to set this to a fixed value which is set to 2GB in our case. It uses the CLFUS (Clocked Least Frequently Used by Size) algorithm and supports compression as well. 

## Health Checking

We need to enable the health check plugin for this functionality in the `plugin.config` file:

```
...
healthchecks.so /etc/trafficserver/healtchecks.conf
```

then set our checking URL in the `healtchecks.conf` file we specified above:

```
/check /etc/trafficserver/ts-alive text/plain 200 403 
```

then create the ts-alive file:

```
RUNNING
```

and after reloading the server:

```
root@ip-172-31-47-28:~# traffic_ctl config reload
```

the TS will respond to the health check queries at the `/check` path with the string `RUNNING` and http status code `200`.

```
igorc@igor-laptop:~$ curl -ksSNiL https://proxy.encompasshost.com/check
HTTP/1.1 200 OK
Content-Type: text/plain
Cache-Control: no-cache
Content-Length: 8
Date: Mon, 16 Jul 2017 05:18:05 GMT
Age: 0
Connection: keep-alive
Via: http/1.1 proxy.encompasshost.com (ATS [uSc sSf pSeN:t c  i p sS])
Server: ATS/7.1.0
 
RUNNING
```

## The Via Header

Enable the detailed Via header stats in `records.config` and hide the Traffic Server name and version details:

```
CONFIG proxy.config.http.insert_request_via_str INT 1
CONFIG proxy.config.http.insert_response_via_str INT 3
CONFIG proxy.config.http.response_via_str STRING ATS
```

To decode the string we can use the `traffic_via` tool:

```
root@ip-172-31-47-28:~# traffic_via  '[cHs f ]'
Via header is [cHs f ], Length is 8
Via Header Details:
Result of Traffic Server cache lookup for URL          :in cache, fresh (a cache "HIT")
Response information received from origin server       :no server connection needed
Result of document write-to-cache:                     :no cache write performed
```

I have enabled detailed stats (proxy.config.http.response_via_str INT 3):

```
root@ip-172-31-47-28:~# traffic_via 'uScHs f p eN:t cCHi p s '
Via header is uScHs f p eN:t cCHi p s , Length is 24
Via Header Details:
Request headers received from client                   :simple request (not conditional)
Result of Traffic Server cache lookup for URL          :in cache, fresh (a cache "HIT")
Response information received from origin server       :no server connection needed
Result of document write-to-cache:                     :no cache write performed
Proxy operation result                                 :unknown
Error codes (if any)                                   :no error
Tunnel info                                            :no tunneling
Cache Type                                             :cache
Cache Lookup Result                                    :cache hit
ICP status                                             :no icp
Parent proxy connection status                         :no parent proxy or unknown
Origin server connection status                        :no server connection needed
```

## Header Rewriting

First we enable the `header_rewrite` plugin in the `plugin.config` file:

```
header_rewrite.so /etc/trafficserver/header_rewrite.conf
```

pointing it to a `header_rewrite.conf` file which we create and where we put our custom configuration:

```
# Remove the Server header
cond %{SEND_RESPONSE_HDR_HOOK} [AND]
cond %{HEADER:server} =ATS/7.1.0
    rm-header server

# Experimental GeoIP plugin
cond %{SEND_RESPONSE_HDR_HOOK} [AND]
cond %${GEO:COUNTRY} /(UK|AU)/
    set-header X-Geo-Country %{GEO:COUNTRY}
 
cond %{SEND_REQUEST_HDR_HOOK}
    set-header Origin https://proxy.encompasshost.com
```

We can see here how we can use different hooks to set, remove or rewrite various headers both towards the client and the origin server.

## Other Custom Configuration

The configuration below shows the settings I used to enable the very simple web UI the TS provides, set the server proxy name, protection from Thundering Herd effect (over-flooding the origin server with requests for expired cache on restart after extended time of being stopped), and Congestion Control (in case the origin server gets overloaded and responds slowly):

```
# Enable cache UI
CONFIG proxy.config.http_ui_enabled INT 1
 
# Set PROXY name
CONFIG proxy.config.proxy_name STRING proxy.encompasshost.com
 
# Prevent Thundering Herd effect
CONFIG proxy.config.cache.enable_read_while_writer INT 1
CONFIG proxy.config.http.background_fill_active_timeout INT 0
CONFIG proxy.config.http.background_fill_completed_threshold FLOAT 0.000000
CONFIG proxy.config.cache.max_doc_size INT 0
CONFIG proxy.config.cache.read_while_writer.max_retries INT 10
CONFIG proxy.config.cache.read_while_writer_retry.delay INT 50
 
# Congestion Control
CONFIG proxy.config.http.congestion_control.enabled INT 1
# Open Read Retry Timeout
CONFIG proxy.config.http.cache.max_open_read_retries INT 5
CONFIG proxy.config.http.cache.open_read_retry_time INT 10
```

The UI access is being protected by the following map in the `remap.config` file:

```
map https://proxy.encompasshost.com/cache/ https://{cache} @action=allow @src_ip=<office-ip> @src_ip=<another-office-ip>
```

allowing access to the UI at https://proxy.encompasshost.com/cache/ only from our offices.

### Detecting CORS

The Origin already has Apache proxy running on the same server hosting several virtual domains. To help with the pre-flight OPTIONS calls that try to detect CORS I added the following to the Origin VHost in Apache:

```
# For Pre-flight requests to Tomcat app
# We can set Allow-Origin to "*" since the app has its own
# whitelist for the sites/domains allowed via CORS
SetEnvIf Request_Method "OPTIONS" IS_OPTIONS_REQUEST
Header add Access-Control-Allow-Origin: "*" env=IS_OPTIONS_REQUEST
Header add Access-Control-Allow-Methods: "GET, HEAD, POST, TRACE, OPTIONS" env=IS_OPTIONS_REQUEST
Header set Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization" env=IS_OPTIONS_REQUEST
```

based on the `Accept` header that Origin sends itself.

## Plugins

The following plugins are installed by TS:

```
root@ip-172-31-47-28:~# ls -1 /usr/local/libexec/trafficserver/*.so
authproxy.so
background_fetch.so
combo_handler.so
conf_remap.so
esi.so
generator.so
gzip.so
header_rewrite.so
healthchecks.so
libloader.so
regex_remap.so
regex_revalidate.so
s3_auth.so
stats_over_http.so
tcpinfo.so
xdebug.so
```
Compile with `--enable-experimental-plugins` to enable some optional ones. The plugins I have configured are shown below:

```
root@ip-172-31-47-28:~# vi /etc/trafficserver/plugin.config
[...]
healthchecks.so /etc/trafficserver/healtchecks.conf
header_rewrite.so /etc/trafficserver/header_rewrite.conf
```

## Logging

The default logs directory when installed from sources is `/usr/local/var/log/trafficserver`. For convenience we create a symlink to `/var/log`:

```
root@ip-172-31-47-28:~# ln -s /usr/local/var/log/trafficserver /var/log/trafficserver
```

The following config in the records.config file defines the logging behavior like max size and log rotation:

```
CONFIG proxy.config.log.logging_enabled INT 3
CONFIG proxy.config.log.max_space_mb_for_logs INT 25000
CONFIG proxy.config.log.max_space_mb_headroom INT 1000
CONFIG proxy.config.log.rolling_enabled INT 1
CONFIG proxy.config.log.rolling_interval_sec INT 86400
CONFIG proxy.config.log.rolling_size_mb INT 10
CONFIG proxy.config.log.auto_delete_rolled_files INT 1
CONFIG proxy.config.log.periodic_tasks_interval INT 5
```

The logs to monitor:

```
root@ip-172-31-47-28:~# tail -f /var/log/trafficserver/manager.log
root@ip-172-31-47-28:~# tail -f /var/log/trafficserver/diags.log
root@ip-172-31-47-28:~# tail -f /var/log/trafficserver/error.log
```

## Operations and Tools

Use the binary to start/stop the server:

```
root@ip-172-31-47-28:~# /usr/local/bin/trafficserver start
 * Starting Apache Traffic Server trafficserver
 
root@ip-172-31-47-28:~# tail -f /var/log/trafficserver/diags.log
[Jul 16 05:33:10.490] Server {0x2b9503c2b840} STATUS: opened /var/log/trafficserver/diags.log
[Jul 16 05:33:10.491] Server {0x2b9503c2b840} NOTE: updated diags config
[Jul 16 05:33:10.494] Server {0x2b9503c2b840} NOTE: cache clustering disabled
[Jul 16 05:33:10.495] Server {0x2b9503c2b840} NOTE: ip_allow.config updated, reloading
[Jul 16 05:33:10.497] Server {0x2b9503c2b840} NOTE: cache clustering disabled
[Jul 16 05:33:10.498] Server {0x2b9503c2b840} NOTE: logging initialized[3], logging_mode = 3
[Jul 16 05:33:10.498] Server {0x2b9503c2b840} NOTE: loading plugin '/usr/local/libexec/trafficserver/healthchecks.so'
[Jul 16 05:33:10.513] Server {0x2b9503c2b840} NOTE: loading SSL certificate configuration from /usr/local/etc/trafficserver/ssl_multicert.config
[Jul 16 05:33:10.533] Server {0x2b9503c2b840} NOTE: traffic server running
[Jul 16 05:33:10.560] Server {0x2b950a733700} NOTE: cache enabled
```

This will start all 3 services described in the Introduction section. Check the error file for issues:

```
root@ip-172-31-47-28:~# tail -f /var/log/trafficserver/error.log
```

Use the `traffic_top` tool for Linux system top like overview of the caching:

![traffic_top](/blog/images/traffic_top.png "traffic_top")
*Cache overview by traffic_top*

Use the `traffic_logstats` tool to quickly check overall or per origin stats:

```
root@ip-172-31-47-28:~# traffic_logstats -o origin.encompasshost.com
                               Traffic summary
Origin Server                               Hits         Misses         Errors
------------------------------------------------------------------------------
origin.encompasshost.com                     1,289          2,683             34
==============================================================================
                            origin.encompasshost.com
Request Result                         Count    Percent       Bytes    Percent
------------------------------------------------------------------------------
Cache hit                                578     14.43%     56.96MB     33.39%
Cache hit RAM                            663     16.55%     38.15MB     22.37%
Cache hit IMS                             48      1.20%      7.53MB      4.41%
Cache hit refresh                          0      0.00%      0.00KB      0.00%
Cache hit other                            0      0.00%      0.00KB      0.00%
Cache hit total                        1,289     32.18%    102.64MB     60.17%
Cache miss                             2,675     66.77%     67.78MB     39.73%
Cache miss IMS                             8      0.20%      1.06KB      0.00%
Cache miss refresh                         0      0.00%      0.00KB      0.00%
Cache miss other                           0      0.00%      0.00KB      0.00%
Cache miss total                       2,683     66.97%     67.78MB     39.73%
Client aborted                            20      0.50%    170.67KB      0.10%
Connect failed                             1      0.02%      0.48KB      0.00%
Invalid request                            0      0.00%      0.00KB      0.00%
Unknown error(99)                         13      0.32%      0.00KB      0.00%
Other errors                               0      0.00%      0.00KB      0.00%
Errors total                              34      0.85%    171.15KB      0.10%
..............................................................................
Total requests                         4,006    100.00%    170.59MB    100.00%
 
[...]
```

We can use `traffic_ctl` to get/set variables and seamlessly reload the configuration without restarting and loosing the RAM cache:

```
$ sudo traffic_ctl config get VARIABLE
$ sudo traffic_ctl config set VARIABLE VALUE
$ sudo traffic_ctl config reload
```

The server also produces `Squid` type binary logs which we can check for hits and misses using the `traffic_logcat` tool:

```
root@ip-172-31-47-28:~# traffic_logcat /var/log/trafficserver/squid.blog | less
```

# Conclusion

Apache TS presents a stable, fast and scalable caching proxy platform. We can easily extend the server created to host many other domains. Using `Route53` we can easily turn this into a CDN and have a server per region for each of the cached domains. The benefit of this compared to an AWS CloudFront CDN for example, apart for the obvious one when we have an application that does not support URL rewriting in order to serve assets from CDN, is that we can handle many domains from a single cache instance where in CloudFront we have to create a separate CDN instance for each origin domain. Depending on the amount of CDN caches we create in CloudFront this feature can quickly become very expensive. It also provides the benefit of having a full control and fine tuning the cache and/or proxy settings to solve any issues that might arise and accommodate any kind of applications. This is not possible with a pre-made solution like CloudFront where the options are limited by the framework and its features are not customer specific but are tailored for general public usage.