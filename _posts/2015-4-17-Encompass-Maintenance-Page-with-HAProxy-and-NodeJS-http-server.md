---
type: posts
header:
  teaser: '4940499208_b79b77fb0a_z.jpg'
title: 'Setting up Encompass Maintenance Page with HAProxy and NodeJS http-server'
categories: 
  - High-Availability
tags: [haproxy]
date: 2015-4-17
---

At Encompass we use HAProxy as a load balancer due to its speed, stability and welth of features. This is how we set our maintenance page to be servered by HAProxy during a maintanance window when our application is offline.

## Prepare the files

Copy the maintenance page files into `/var/www` on the `HAProxy` load balancers.

```
$ sudo mkdir /var/www
$ sudo cp maintenance_page.zip /var/www/
$ sudo unzip /var/www/maintenance_page.zip
$ sudo mv /var/www/maintenance.html /var/www/index.html
$ sudo rm /var/www/maintenance_page.zip
$ ls -l /var/www
total 16
drwxr-xr-x 2 root root 4096 Apr 17 15:03 font
drwxr-xr-x 2 root root 4096 Apr 17 15:06 img
-rw-r--r-- 1 root root 4613 Apr 17 15:12 index.html
```

## Install and setup http-server

The `http-server` is super light `Node.js` web server. It's also super easy to setup so for those reasons it is `http-server` that is used to host our maintenance page.

```
$ sudo aptitude install npm supervisord
$ sudo npm install http-server -g
$ sudo ln -s /usr/bin/nodejs /usr/bin/node
```

Then we create the `Supervisord` config file `/etc/supervisor/conf.d/local.conf` so it can manage the server:

```
[program:http-server]
command=/usr/local/bin/http-server -a localhost -p 8080 -r -c 3600 /var/www/
process_name=%(program_name)s
autostart=true
autorestart=true
stopsignal=TERM
user=www-data
stdout_logfile=/var/log/http-server.log
stdout_logfile_maxbytes=1MB
stdout_logfile_backups=3
stderr_logfile=/var/log/http-server.log
```

Then we tell `Supervisord` to reload its configuration:

```
$ sudo supervisorctl reread
http-server: changed

$ sudo supervisorctl reload
Restarted supervisord
 
$ sudo supervisorctl status
http-server                      RUNNING    pid 8483, uptime 0:03:15
```

This is all taken care of by `Ansible` during HAProxy setup.

## Configure HAProxy

We add the `http-server` server to the backend server pool as sorry server (backup), we terminate the SSL on the HAProxy:

```
...
defaults
...
    errorfile 503 /dev/null
...

listen https-in
...
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100 error-limit 1 on-error mark-down agent-port 9707 agent-inter 30s
    server server01 server01:8080 check observe layer7
    server server02 server02:8080 check observe layer7
    server localhost 127.0.0.1:8080 maxconn 500 backup
```

We restart the service:

```
$ sudo service haproxy restart
```

and to test we simply block the route to the app servers (on both HAP's since we run a cluster):

```
$ sudo iptables -I OUTPUT -p tcp -m tcp --destination-port 443 -j REJECT
```

The HAP's will not be able to reach the backend servers and will think they are all down and in couple of seconds we will see the Maintenance page being displayed. We then remove the firewall rule:

```
$ sudo iptables -D OUTPUT 1
```

to get our application back and resume normal operation.