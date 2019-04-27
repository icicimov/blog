---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'HAProxy dynamic backends with Consul and Consul Template in AWS'
categories: 
  - DevOps
tags: [aws, haproxy, consul]
date: 2017-6-21
---

[Consul](http://consul.io/) has been part of our infrastructure for almost two years now. Each of our VPCs gets Consul cluster installed and configured via [Terraform](http://terraform.io/) and [Ansible](https://www.ansible.com/) at the VPC creation time. Each service running on the EC2 instances in the VPC then registers it self into the cluster via Consul client installed and configured on the instance. The services are registered under the default consul domain as `<service-name>.service.consul`.

We are also running `dnsmasq` on each HAProxy instance that points the `consul` domain to the Consul DNS resolver:

```
# /etc/dnsmasq.d/10-consul 
server=/.consul/127.0.0.1#8600
server=/eu-west-1a.compute.internal/10.77.0.2
```

so the HAP instances can easily discover the members of some service like:

```
root@ip-10-77-2-54:~# dig +short tomcat.service.consul
10.77.3.227
10.77.4.234
```

And in HAProxy (1.7+) we have:

```
resolvers dns_resolvers
    nameserver dns0 127.0.0.1:53
    nameserver dns2 8.8.8.8:53
    nameserver dns3 8.8.4.4:53
    resolve_retries       3
    timeout retry         1s
    hold other           30s
    hold refused         30s
    hold nx              30s
    hold timeout         30s
    hold valid           10s
```

utilizing the DNS setup.

Apart from the main `/etc/haproxy/haproxy.cfg` config file that takes care of all the frontends, SSL termination and static backends, we have a 
separate config file `/etc/haproxy/conf.d/01-backends-tomcat.cfg` for our application (tomcat) dynamic backend:

```
# /opt/consul-template/templates/haproxy.ctmpl
backend tomcats
    mode http
[...]
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100 error-limit 100 on-error mark-down agent-port 9707 agent-inter 30s init-addr none
{% raw %}{{range service "tomcat"}}
    server {{.Node}} {{.Address}}:{{.Port}} check port {{.Port}} observe layer7{{end}}{% endraw %}
    server localhost 127.0.0.1:8090 maxconn 500 backup 
```

Having this config structure enables us to easily "scale" HAProxy by adding separate config file for every new dynamic backend. 

To accommodate this setup we need to slightly tweak our HAP startup script in `/etc/init.d/haproxy` though:

```
[...]
EXTRAOPTS=
for file in /etc/haproxy/conf.d/*.cfg; do test -f $file && EXTRAOPTS="$EXTRAOPTS -f $file"; done
[...]
```

so that HAP concatenates in memory these config files with the main one. In case of Systemd my Unit file looks like this:

```
[Unit]
Description=HAProxy Load Balancer
Documentation=man:haproxy(1)
Documentation=file:/usr/share/doc/haproxy/configuration.txt.gz
After=network.target syslog.service
Wants=syslog.service
StartLimitIntervalSec=0

[Service]
Environment="CONFIG=/etc/haproxy/haproxy.cfg" "PIDFILE=/run/haproxy.pid" "EXTRAOPTS="
EnvironmentFile=-/etc/default/haproxy
ExecStartPre=/bin/sh -c 'EXTRAOPTS='';for file in /etc/haproxy/conf.d/*.cfg; do test -f $file && EXTRAOPTS="$EXTRAOPTS -f $file"; done; echo EXTRAOPTS=\\\""$EXTRAOPTS"\\\" > /etc/default/haproxy'
ExecStartPre=/usr/sbin/haproxy -f $CONFIG -c -q $EXTRAOPTS
ExecStart=/usr/sbin/haproxy-systemd-wrapper -f $CONFIG -p $PIDFILE $EXTRAOPTS
ExecReload=/usr/sbin/haproxy -f $CONFIG -c -q $EXTRAOPTS
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
Restart=always
RestartSec=2s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

In turn each of those files is controlled by Consul Template that monitors the members of the Service the backend servers belong to via Consul and dynamically updates the file(s) if necessary and reloads HAProxy. Example of such a template:

```
# /opt/consul-template/config/consul-template.cfg
consul {
  auth {
    enabled = false
  }

  address = "127.0.0.1:8500"

  retry {
    enabled = true
    attempts = 12
    backoff = "250ms"
    max_backoff = "1m"
  }

  ssl {
    enabled = false
  }
}

reload_signal = "SIGHUP"
kill_signal = "SIGINT"
max_stale = "10m"
log_level = "info"

wait {
  min = "5s"
  max = "10s"
}

template {
  source = "/opt/consul-template/templates/haproxy.ctmpl"
  destination = "/etc/haproxy/conf.d/01-backends-tomcat.cfg"
  command = "sudo /etc/init.d/haproxy reload || true"
  command_timeout = "60s"
  perms = 0600
  backup = true 
  wait = "2s:6s"
}
```

[Consul Template](https://github.com/hashicorp/consul-template) is installed from source under `/opt/consul-template` and is running as a service (upstart on Ubuntu-14.04) on each of the proxies under `consul` user account:

```
# /etc/init/consul-template.conf 
description "Consul template process"

start on (local-filesystems and net-device-up IFACE=eth0)
stop on runlevel [!12345]

pre-start script
    mkdir -p -m 0755 /var/log/consul-template
    chown consul:consul /var/log/consul-template
end script

respawn
respawn limit 10 10
kill timeout 10

exec setuidgid consul /usr/local/bin/consul-template \
-config=/opt/consul-template/config/consul-template.cfg > /var/log/consul-template/consul-template.log 2>&1
```

To insure the `consul` user has proper permissions over HAP config files we set the following ACL on the `/etc/haproxy/conf.d` directory:

```
setfacl -R -d -m u:consul:rw /etc/haproxy/conf.d
```

and in `/etc/sudoers`:

```
consul ALL=(root) NOPASSWD:/usr/bin/lsof, ..., /etc/init.d/haproxy reload
```

we make sure the `consul` user has permission to reload HAP as sudo user. Now every time the rendered Consul Template `/opt/consul-template/config/consul-template.cfg` file differs from the `/etc/haproxy/conf.d/01-backends-tomcat.cfg`, Consul Template copies it over and reloads HAP so it can pickup the changes:

```
root@ip-10-77-0-94:~# tail -f /var/log/consul-template/consul-template.log 
2017/08/29 01:59:00.572434 [INFO] (runner) rendered "/opt/consul-template/templates/haproxy.ctmpl" => "/etc/haproxy/conf.d/01-backends-tomcat.cfg"
2017/08/29 01:59:00.572454 [INFO] (runner) executing command "sudo /etc/init.d/haproxy reload || true" from "/opt/consul-template/templates/haproxy.ctmpl" => "/etc/haproxy/conf.d/01-backends-tomcat.cfg"
2017/08/29 01:59:00.572492 [INFO] (child) spawning: sudo /etc/init.d/haproxy reload
 * Reloading haproxy haproxy
   ...done.
```

And that's it, every time a new tomcat instance gets created or terminated, Consul Template will detect that and update and reload HAProxy with the new backend configuration.  

**UPDATE** 

Since Haproxy's introduction of `resolvers` and support for SRV DNS records in `server-template` I have ditched `consul-template` which makes the overall setup (one moving part less) and configuration much simpler. What I have now in Haproxy 1.8+ is:  

```
resolvers consul
    #nameserver consul 127.0.0.1:8600   # choose this or dnsmasq below
    nameserver dnsmasq 127.0.0.1:53     # to use dnsmasq and its caching
    accepted_payload_size 8192
    resolve_retries       30
    timeout resolve       1s
    timeout retry         2s
    hold valid            30s
    hold other            30s
    hold refused          30s
    hold nx               30s
    hold timeout          30s
    hold obsolete         30s

backend tomcats
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 ...
    server-template tomcats 10 _tomcat._tcp.service.consul resolvers consul resolve-prefer ipv4 check observe layer7
```

In other words the backend servers discovery and configuration updates are now entirely left to Haproxy. Now the backend looks like this in the monitoring console:

[![Haproxy server-template backend](/blog/images/haproxy-consul-discovery.png)](/blog/images/haproxy-consul-discovery.png "Haproxy server-template backend")

I also have introduced a `server-state-file` file to save the servers state on reload to a file:

```
global
    server-state-base /var/lib/haproxy
    server-state-file state

defaults
    load-server-state-from-file global
    default-server init-addr last,libc,none
```

and have this added to the systemd service to support this functionality:

```
[Service]
ExecReload=/bin/echo "show servers state" | /usr/bin/socat stdio /run/haproxy/admin.sock > /var/lib/haproxy/state
```