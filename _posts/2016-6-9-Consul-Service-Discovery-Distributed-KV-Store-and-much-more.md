---
type: posts
header:
  teaser: 'consul.jpg'
title: 'Consul Service Discovery, Distributed KV Store and much more'
categories: 
  - DevOps
tags: ['consul']
date: 2015-7-31
excerpt: "Consul is completely distributed, highly available service discovery tool that can scale to thousands of nodes and services across multiple datacenters. In a ever growing cloud environment, service discovery becomes a useful abstraction to map the specific designations and port numbers of the your services/load-balancers to nice, semantic names."
---
{% include toc %}
[Consul](http://www.consul.io/) is completely distributed, highly available service discovery tool that can scale to thousands of nodes and services across multiple datacenters. In a ever growing cloud environment, service discovery becomes a useful abstraction to map the specific designations and port numbers of the your services/load-balancers to nice, semantic names. The utility of this is being able to refer to things by semantic names instead of IP address, or even hostnames.

An instance of the Consul agent runs on every machine of the services that we want to publish. The instances of Consul form a Consul cluster. Each machine has a directory in which are stored `service definition` files for each service we wish to announce. We then hit either a REST endpoint or do a DNS query to render an IP. The DNS-compatible interface is especially nice feature and it provides for automatic caching too.

Multiple machines can announce themselves for the same services, and they'll all be enumerated in the result. In fact, Consul will use a load-balancing strategy similar to round-robin when it returns DNS answers. The information about the nodes and services leaving and/or joining the cluster is propagated to every single member of the cluster via Serf and the Gossip protocol.

For more info visit the [Consul web site](http://www.consul.io/intro/index.html).

# Installation and Setup

Installation and setup of Consul is fairly simple. it consists of single agent binary that can be run in server or client mode. The nodes that run in server mode will form the initial cluster to which the client agents join later. The servers take care of the cluster quorum and leader election via `RAFT` consensus protocol which is very similar to `PAXOS` used in the revolutionary `Ceph` distributed HA binary object storage. As pointed on their web site, it is best to run with 3 to 5 server nodes to avoid any possible issues in case of reduced cluster capacity, ie lost of quorum (`(N+1) / 2` number of nodes are needed for quorum, for example 2 nodes in cluster of 3). The data consistency in the cluster is achieved by the fact that every single write operation is managed only by the leader. The read operations are more flexible and can be managed through several modes, like leader only mode or stale mode where any server node can answer the read.

The installation is simple download of the latest tarball and dropping the extracted binary somewhere in the user's PATH:

```
root@ip-10-155-0-180:~# wget https://dl.bintray.com/mitchellh/consul/0.5.2_linux_amd64.zip
root@ip-10-155-0-180:~# unzip -qq -o 0.5.2_linux_amd64.zip                  
root@ip-10-155-0-180:~# mv consul /usr/local/bin/
```

then we create consul user and configuration and data directory for the service:

```
root@ip-10-155-0-180:~# useradd -c "Consul user" -c /bin/bash -m consul
root@ip-10-155-0-180:~# mkdir -p /etc/consul.d/{bootstrap,server,client,ssl}
root@ip-10-155-0-180:~# mkdir /var/consul
root@ip-10-155-0-180:~# chown consul\: /var/consul
```

Now we can start the agent in server or client mode. On the server nodes we create the following `/etc/consul.d/server/config.json` configuration file (the encryption key given here is **NOT** the one used on the servers of course):

```
{
    "bootstrap_expect": 2,
    "server": true,
    "leave_on_terminate": true,
    "rejoin_after_leave": true,
    "datacenter": "mydomain",
    "data_dir": "/var/consul",
    "encrypt": "O9gXBpYXcnG7GUC17pkL6w==",
    "ca_file": "/etc/consul.d/ssl/cacert.pem",
    "cert_file": "/etc/consul.d/ssl/consul.pem",
    "key_file": "/etc/consul.d/ssl/consul.key",
    "verify_incoming": true,
    "verify_outgoing": true,
    "log_level": "INFO",
    "enable_syslog": true,
    "start_join": ["10.155.0.180", "10.155.10.176", "10.155.100.206"]
}
```

All configuration in Consul is via JSON formatted files. We can see the IP's of the other two Consul servers that form the cluster. All 3 nodes have identical config file. Another thing to notice is the use of the encryption token and SSL/TLS certificates for high security. The nodes will communicate with each other only if they have a valid certificate and the traffic will be encrypted with the token provided. The token can be simply generated:

```
root@ip-10-155-0-180:~# consul keygen
O9gXBpYXcnG7GUC17pkL6w==
```

On the client nodes we have slightly different configuration:

```
{
    "server": false,
    "datacenter": "mydomain",
    "data_dir": "/var/consul",
    "ui_dir": "/home/consul/webui",
    "encrypt": "O9gXBpYXcnG7GUC17pkL6w==",
    "ca_file": "/etc/consul.d/ssl/cacert.pem",
    "cert_file": "/etc/consul.d/ssl/consul.pem",
    "key_file": "/etc/consul.d/ssl/consul.key",
    "verify_incoming": true,
    "verify_outgoing": true,
    "log_level": "INFO",
    "enable_syslog": true,
    "start_join": ["10.155.0.180", "10.155.10.176", "10.155.100.206"]
}
```

the main difference being in setting `server` to `false`. When In client mode, the node can also host the Consul web UI console, which is simple monitoring and configuration utility for Consul. To install it:

```
root@ip-10-155-0-59:~# wget -q https://dl.bintray.com/mitchellh/consul/0.5.2_web_ui.zip
root@ip-10-155-0-59:~# unzip -qq -o 0.5.2_web_ui.zip
root@ip-10-155-0-59:~# mv dist /home/consul/webui
```

Consul serves the HTTP console on port `8500` and only on the local interface. We can use ssh `SOCKS` proxy for example to establish a tunnel:

```
igorc@igor-laptop:~/devops$ ssh -i $EC2_KEYPAIR -N -f -L 8500:localhost:8500 user@10.155.0.59
```

then point the browser to [](http://localhost:8500) to access the Web UI. This can be implemented via authentication protected SSL proxy for example as well. The relevant NGINX proxy setup for the Consul domain:

```
...
    location / {
        proxy_pass http://127.0.0.1:8500/ui/;
        auth_ldap "Restricted";
        auth_ldap_servers ldap1;
        auth_ldap_servers ldap2;
    }
 
  location ~ \.(css|js|png|jpeg|jpg|gif|ico|swf|flv|pdf|zip)$ {
        expires 24h;
        add_header Cache-Control public;
        auth_ldap "Restricted";
        auth_ldap_servers ldap1;
        auth_ldap_servers ldap2;
  }
 
  # Forward consul API requests
  location ~ ^/v1/.*$ {
        proxy_pass http://127.0.0.1:8500;   
        proxy_read_timeout 90;
        auth_ldap "Restricted";
        auth_ldap_servers ldap1;
        auth_ldap_servers ldap2;
  }
...
```

We can notice our Web UI is protected by LDAP authentication so only registered users can get access.

Previously I mentioned that the node communication in the datacenter is protected with SSL certificates. I have used our existing `PKIX` setup to generate the files. First I created a `v3` file with that describes the certificate usage and purpose:

```
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
```

Then generated private key and CSR and signed it (note the password given below is **NOT** the one used on the servers of course):

```
user@host:~/.CA/Encompass$ export SSLPASS=password
 
user@host:~/.CA/Encompass$ /usr/bin/openssl req -new -keyform PEM -outform PEM \
-newkey rsa:2048 -sha256 -nodes -config /home/user/.CA/Encompass/openssl.cnf \
-out /home/user/.CA/Encompass/req/consul.req \
-keyout /home/user/.CA/Encompass/keys/consul.key \
-subj '/C=AU/ST=New South Wales/L=Sydney/O=Encompass Corporation Ltd./OU=DevOps/CN=consul.encompasscorporation.com'
 
user@host:~/.CA/Encompass$ /usr/bin/openssl x509 -req -in /home/user/.CA/Encompass/req/consul.req \
-CA /home/user/.CA/Encompass/cacert.pem -passin env:SSLPASS -CAkey /home/user/.CA/Encompass/cacert.key \
-out /home/user/.CA/Encompass/certs/consul.pem -CAserial /home/user/.CA/Encompass/serial \
-extfile /home/user/.CA/Encompass/openssl.cnf -extensions v3_req -days 7300
```

The `consul.key`, `consul.pem` and `cacert.pem` files will be uploaded to the ssl directory on each Consul node.

To finish off everything we install a small upstart script `/etc/init/consul.conf` so we can run Consul as service:

```
description "Consul server process"
 
start on (local-filesystems and net-device-up IFACE=eth0)
stop on runlevel [!12345]
 
respawn
respawn limit 10 10
kill timeout 10
 
setuid consul
setgid consul
 
exec consul agent -config-dir /etc/consul.d/server
```

On the client nodes we just replace `/etc/consul.d/server` with `/etc/consul.d/client`. After all nodes and services are configured the cluster state will look like this:

```
igor.cicimov@ip-10-155-0-180:~$ consul members
Node               Address              Status  Type    Build  Protocol
ip-10-155-0-180    10.155.0.180:8301    alive   server  0.5.1  2
ip-10-155-100-206  10.155.100.206:8301  alive   server  0.5.1  2
ip-10-155-0-59     10.155.0.59:8301     alive   client  0.5.1  2
ip-10-155-0-141    10.155.0.141:8301    alive   client  0.5.2  2
ip-10-155-0-48     10.155.0.48:8301     alive   client  0.5.2  2
ip-10-155-10-111   10.155.10.111:8301   alive   client  0.5.1  2
ip-10-155-1-206    10.155.1.206:8301    alive   client  0.5.2  2
ip-10-155-22-171   10.155.22.171:8301   alive   client  0.5.1  2
ip-10-155-11-107   10.155.11.107:8301   alive   client  0.5.1  2
ip-10-155-2-51     10.155.2.51:8301     alive   client  0.5.1  2
ip-10-155-10-176   10.155.10.176:8301   alive   server  0.5.1  2
ip-10-155-10-167   10.155.10.167:8301   alive   client  0.5.2  2
ip-10-155-1-207    10.155.1.207:8301    alive   client  0.5.1  2
ip-10-155-111-84   10.155.111.84:8301   alive   client  0.5.2  2
ip-10-155-11-226   10.155.11.226:8301   alive   client  0.5.2  2
ip-10-155-0-172    10.155.0.172:8301    alive   client  0.5.1  2
ip-10-155-222-230  10.155.222.230:8301  alive   client  0.5.1  2
```

## Adding Services and Checks

As we mentioned before we add services by simply dropping appropriate JSON formatted file describing the service and its health checks in the Consul configuration directory. For example all our Tomcat nodes have the following service definition:

```
{
    "service": {
        "name": "tomcat",
        "port": 80,
        "tags": ["tomcat", "mydomain"],
        "check": {
            "script": "curl -X GET -k -I https://localhost:443/resource/hc/application > /dev/null 2>&1",
            "interval": "10s"
        }
    }
}
```

Our Mongo services file `/etc/consul.d/client/mongo.json` looks like this:

```
{
  "services": [
    {
      "id": "db1",
      "name": "db1",
      "tags": ["mongo","db1","mydomain"],
      "port": 27017,
      "checks": [
        {
          "script": "/usr/bin/mongo --quiet --port 27017 -u <user> -p <password> db1 --eval 'db.stats()' > /dev/null 2>&1",
          "interval": "10s"
        }
      ]
    },
    {
      "id": "db2",
      "name": "db2",
      "tags": ["mongo","db2","mydomain"],
      "port": 27018,
      "checks": [
        {
          "script": "/usr/bin/mongo --quiet --port 27018 -u <user> -p <password> db2 --eval 'db.stats()' > /dev/null 2>&1",
          "interval": "10s"
        }
      ]
    }
  ]
}
```

And for ElasticSearch we have `/etc/consul.d/client/es.json`:

```
{
    "service": {
        "name": "elasticsearch",
        "port": 9200,
        "tags": ["elasticsearch", "mydomain"],
        "check": {
            "http": "http://localhost:9200/_cluster/health?pretty=true",
            "interval": "10s"
        }
    }
}
```

For GlusterFS:

```
{
    "service": {
        "name": "glusterfs",
        "tags": ["glusterfs", "mydomain"],
        "check": {
            "service_id": "glusterfs",
            "script": "/usr/local/bin/gluster_status.sh",
            "interval": "10s"
        }
    }
}
```

And the Gluster health check script `/usr/local/bin/gluster_status.sh` looks like this:

```
#!/bin/bash
status=0
# Ensure that all peers are connected
peers_disconn=$(gluster peer status | grep -B3 Disconnected | xargs -L 3 | cut -d' ' -f1-2)
[[ "$peers_disconn" != "" ]] && echo -e "Peer disconnected.\n$peers_disconn" && exit 1
for vol in $(gluster volume list)
do
  gluster volume status gfs-volume-mydomain detail | grep -E "Brick|Online" | \
  sed 'N;s/\n/ /;s/^Brick \{1,\}: Brick //;s/Online \{1,\}: //' | \
  while read -r brick state; do [[ "$state" != "Y" ]] && echo "Offline: $brick" && status=1; done
done
exit $status
```

Basically we can hook up any script we want to the health check. The list of all services:

```
root@ip-10-155-0-59:~# curl -s localhost:8500/v1/catalog/services | jq -r .
{
  "web": [
    "nginx",
    "mydomain"
  ],
  "jmsbroker": [
    "jmsbroker",
    "mydomain"
  ],
  "consul": [],
  "db2": [
    "mongo",
    "db2",
    "mydomain"
  ]
  "dns": [
    "dns",
    "nat",
    "mydomain"
  ],
  "elasticsearch": [
    "elasticsearch",
    "mydomain"
  ],
  "glusterfs": [
    "glusterfs",
    "mydomain"
  ],
  "haproxy": [
    "haproxy",
    "mydomain"
  ],
  "db1": [
    "mongo",
    "db1",
    "mydomain"
  ],
  "tomcat": [
    "tomcat",
    "mydomain"
  ]
}
```

All this services get registered with the cluster when the Consul agent starts up on the host.

## REST API

As we can see from the last command above, Consul offers REST API for client interaction with its end points. The API can be used to perform CRUD operations on nodes, services, checks, configuration, and more. The endpoints are versioned to enable changes without breaking backwards compatibility.

Each endpoint manages a different aspect of Consul:

* kv - Key/Value store
* agent - Consul Agent
* catalog - Nodes and services
* health - Health checks
* session - Sessions
* acl - Access Control Lists
* event - User Events
* status - Consul system status
* internal - Internal APIs

Each of these are documented in detail on the Consul page. Some examples of querying several end points:

```
root@ip-10-133-0-189:~# curl -s localhost:8500/v1/catalog/service/db1 | jq -r '.[].Address'
"10.133.2.159"
"10.133.22.36"
"10.133.222.219"
 
root@ip-10-155-0-59:~# curl -s localhost:8500/v1/catalog/service/jmsbroker | jq -r '.[].Address'
"10.155.1.207"
"10.155.11.107"
 
root@ip-10-155-0-59:~# curl -s localhost:8500/v1/kv/jms/brokers | jq -r '.[].Value' | base64 -d
ip-10-155-1-207:61616,ip-10-155-11-107:61616
```

## DNS API

For the DNS API, the DNS name for services is `NAME.service.consul`. By default, all DNS names are always in the consul namespace, though this is configurable. The service subdomain tells Consul we're querying services, and the `NAME` is the name of the service.

Now this combined with the Services setup can provide a very powerful feature of host type discovery. For example:

```
root@ip-10-155-0-59:~# dig +short @127.0.0.1 -p 8600 tomcat.service.consul
10.155.0.172
10.155.10.111
```

will provide me with all node IP's on which the `tomcat` is configured as a Service. If I run the same command again:

```
root@ip-10-155-0-59:~# dig +short @127.0.0.1 -p 8600 tomcat.service.consul
10.155.10.111
10.155.0.172
```

Consul returns the list in reverse order. Actually on every query it returns the list of hosts in round-robin fashion providing for simple DNS load balancing. This can be very useful feature in case of distributed backend, like multi-node database cluster, so the requests get equally spread across all members.

And in case our service is running on a non standard port we can send a `SRV` query to discover it:

```
root@ip-10-155-0-59:~# dig +short db2.service.consul SRV
1 1 27018 ip-10-155-22-171.node.mydomain.consul.
1 1 27018 ip-10-155-2-51.node.mydomain.consul.
1 1 27018 ip-10-155-222-230.node.mydomain.consul.
```

Now this service runs on port `8600` on local interface only. To make it really useful we want to turn it into default DNS service on each client host. We will do that by installing `dnsmasq`.

```
$ sudo aptitude install -q -y dnsmasq
$ sudo echo "server=/.consul/127.0.0.1#8600" > /etc/dnsmasq.d/10-consul
$ sudo echo "server=/eu-west-1a.compute.internal/10.155.0.2" >> /etc/dnsmasq.d/10-consul
$ sudo service dnsmasq force-reload
```

Now all DNS queries will be handled by `dnsmasq` and the ones for `.consul` domain will get forwarded to Consul DNS service. Now our DNS query for the consul services and nodes will look like any other DNS query:

```
root@ip-10-155-0-59:~# dig +short tomcat.service.consul
10.155.0.172
10.155.10.111
```

## K/V Store

Another feature offered by Consul is Key/Value store.The K/V structure can be created via the web console or the REST API of course. The KV endpoint is used to access Consul's simple `key/value` store, useful for storing service configuration or other metadata. 

It has only a single endpoint: `/v1/kv/<key>`

The GET, PUT and DELETE methods are all supported. To get the value of a key:

```
root@ip-10-155-0-59:~# curl -s localhost:8500/v1/kv/jms/brokers?raw
ip-10-155-1-207:61616,ip-10-155-11-107:61616
```

By default Consul returns the value `base64` encoded so we need to add `?raw` at the end of the query to get the value in human readable format.

## Templates

The daemon consul-template queries a Consul instance and updates any number of specified templates in the file system. Additionally, consul-template can optionally run arbitrary commands when the update process completes. Same as consul it can be downloaded as a single executable binary and placed in the user's `$PATH`. We then create upstart job:

```
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
-config=/opt/consul-template/config/consul-template.cfg \
> /var/log/consul-template/consul-template.log 2>&1
```

and it's ready to run as service. It takes a template config file as input, queries Consul and places one or more output files in the file system. This files can be some service configuration files, for example consider the following configuration file `/opt/consul-template/config/consul-template.cfg`:

```
consul = "127.0.0.1:8500"
 
template {
  source = "/opt/consul-template/templates/haproxy.ctmpl"
  destination = "/etc/haproxy/haproxy.cfg"
  command = "reload haproxy"
}
```

pointing to the following template file `/opt/consul-template/templates/haproxy.ctmpl`:

```
global
  log 127.0.0.1   local0
  maxconn 4096
  user haproxy
  group haproxy
 
defaults
  log     global
  mode    http
  option  dontlognull
  retries 3
  option  redispatch
  timeout connect 5s
  timeout client 50s
  timeout server 50s
  balance roundrobin
 
frontend https
  maxconn            {% raw %}{{key "service/haproxy/maxconn"}}{% endraw %}
  mode               tcp
  bind               0.0.0.0:443
  default_backend    servers-https
 
backend servers-https
  mode               tcp
  option             tcplog
  balance            roundrobin
{% raw %}{{range service "tomcat"}}
  server {{.Node}} {{.Address}}:{{.Port}} weight 1 check port {{.Port}}{{end}}{% endraw %}
```

After starting, consul-template will process the templates from the config file, produce the following HAProxy config file `/etc/haproxy/haproxy.cfg`:

```
 global
  log 127.0.0.1   local0
  maxconn 4096
  user  haproxy
  group haproxy
 
defaults
  log     global
  mode    http
  option  dontlognull
  retries 3
  option  redispatch
  timeout connect 5s
  timeout client 50s
  timeout server 50s
  balance roundrobin
 
frontend https
  maxconn            200
  mode               tcp
  bind               0.0.0.0:443
  default_backend    servers-https
 
backend servers-https
  mode               tcp
  option             tcplog
  balance            roundrobin
  server ip-10-155-0-172 10.155.0.172:443 weight 1 check port 443
  server ip-10-155-10-111 10.155.10.111:443 weight 1 check port 443
```

and gracefully reload HAProxy so it picks up the changes. Then it will keep monitoring the keys and services set in the template and upon any change it will generate new config file and reload HAProxy. Perfect for self provisioning servers and services.

As another example, the following simple template file:

```
{% raw %}{{range services}}[{{.Name}}]{{range service .Name}}
{{.Address}}{{end}}
{{end}}{% endraw %}
```

will produce an Ansible style inventory file for us:

```
[jmsbroker]
10.155.1.207
10.155.11.107
 
[db2]
10.155.2.51
10.155.22.171
10.155.222.230
 
[consul]
10.155.0.180
10.155.10.176
10.155.100.206
 
[dns]
127.0.0.1
 
[elasticsearch]
10.155.2.51
10.155.22.171
10.155.222.230
 
[db1]
10.155.2.51
10.155.22.171
10.155.222.230
 
[glusterfs]
10.155.1.206
10.155.11.226
10.155.111.84
 
[haproxy]
10.155.0.141
10.155.10.167
 
[tomcat]
10.155.0.172
10.155.10.111
 
[web]
10.155.0.59
```

More details can be found in the [project Git hub](https://github.com/hashicorp/consul-template).

## Watches

Watches are a way of specifying a view of data (e.g. list of nodes, KV pairs, health checks) which is monitored for updates. When an update is detected, an external handler is invoked. A handler can be any executable. As an example, you could watch the status of health checks and notify an external system when a check is critical.

Watches can be configured as part of the agent's configuration, causing them to run once the agent is initialized. Reloading the agent configuration allows for adding or removing watches dynamically.

The following types are supported:

* key - Watch a specific KV pair
* keyprefix - Watch a prefix in the KV store
* services - Watch the list of available services
* nodes - Watch the list of nodes
* service - Watch the instances of a service
* checks - Watch the value of health checks
* event - Watch for custom user events

For example we can set a watch for our jmsbroker key that has the list of the AMQ servers and when it changes we can invoke a script that for example updates Tomcat with the new value:

```
{
  "type": "key",
  "key": "jms/brokers",
  "handler": "/usr/local/bin/update-tomcat-handler.sh"
}
```

## Alerts

To get some kind of alerting out of Consul I have installed and configured consul-alerts. I have set it up on the client host where I have NGINX running as well:

```
root@ip-10-155-0-59:~# wget https://bintray.com/artifact/download/darkcrux/generic/consul-alerts-latest-linux-amd64.tar
root@ip-10-155-0-59:~# tar -xvf consul-alerts-latest-linux-amd64.tar
root@ip-10-155-0-59:~# mv consul-alerts /usr/local/bin/consul-alerts
root@ip-10-155-0-59:~# chmod +x /usr/local/bin/consul-alerts
```

Then we can start the daemon:

```
root@ip-10-155-0-59:~# consul-alerts start --alert-addr=localhost:9000 \
--consul-addr=localhost:8500 --consul-dc=mydomain \
--watch-events --watch-checks & > /dev/null 2>&1
```

The deamon config is in KV store in Consul so we go to the consul web UI where we need to create the KV structure under `checks/` and `config/` folders as described in the Git home page at [](https://github.com/AcalephStorage/consul-alerts), for example set the interval check from default `60` sec to `30`:

```
consul-alerts/config/checks/change-threshold = 30
```

The easiest way to create the KV store is using the REST API though:

```
curl -X PUT -d '30' http://localhost:8500/v1/kv/consul-alerts/config/checks/change-threshold
curl -X PUT -d 'true' http://localhost:8500/v1/kv/consul-alerts/config/notifiers/email/enabled
curl -X PUT -d '["igorc@encompasscorporation.com"]' http://localhost:8500/v1/kv/consul-alerts/config/notifiers/email/receivers
curl -X PUT -d 'smtp.encompasshost.com' http://localhost:8500/v1/kv/consul-alerts/config/notifiers/email/url
curl -X PUT -d '<user>' http://localhost:8500/v1/kv/consul-alerts/config/notifiers/email/username
curl -X PUT -d '<password>' http://localhost:8500/v1/kv/consul-alerts/config/notifiers/email/password
```

We can run this from any host. Now from my local pc I can establish connection to the consul-alerts daemon listening on port 9000 by:

```
igorc@z30:~/Downloads$ ssh -i $EC2_KEYPAIR -N -f -L 9000:localhost:9000 user@10.155.0.59
```

and confirm if some service is working by querying the status of one of the services:

```
igorc@z30:~$ curl 'http://localhost:9000/v1/health?node=ip-10-155-0-141&service=haproxy&check=service:haproxy'
status: passing
output: HTTP GET http://localhost:34180/haproxy_status: 200 OK Output: <html><body><h1>200 OK</h1>
Service ready.
</body></html>
```

Of course this has been converted into service as well in `/etc/init/consul-alerts.conf` file:

```
description "Consul alerts process"
 
start on (local-filesystems and net-device-up IFACE=eth0)
stop on runlevel [!12345]
 
respawn
respawn limit 10 10
kill timeout 10
 
setuid consul
setgid consul
 
exec consul-alerts start --alert-addr=localhost:9000 --consul-addr=localhost:8500 \
--consul-dc=mydomain --watch-events --watch-checks
```

# Conclusion

Consul is a distributed, highly available, datacenter-aware, service discovery and configuration system. It can be used to present services and nodes in a flexible and powerful interface that allows clients to always have an up-to-date view of the infrastructure they are a part of. It can also be used as an automation tool by leveraging its REST and DNS API's, tags and the Kye/Value store providing distributed inventory that the nodes launched in the cluster can query and self provision or configure them self based on their role. It can also provide basic health and service monitoring via its simple and clear Web UI.

For us using Consul helped to streamline our app setups from the hard coded approach we had. The application can discover the DB, ES, JMS and any other backend services by simply referencing their Consul DNS names. Or by querying the REST service API endpoint if it suits better. And just to mention it, it also has a Java and Javascript SDK (among the others) that we can use.

We can use the KV store to keep all our application settings if we want which can be different for each datacenter (read VPC in our case).

By using Watches and events we can monitor KV values and services and upon change we can update server configurations (ie update HAProxy backend servers if number of Tomcats changes), restart services, send emails or even trigger deployments if we want.

We can use Templates to auto configure services upon EC2 instance creation.

And the options go on and on. The potential of Consul is huge and I'm sure anyone can find some (or many) way(s) of using its power.

In terms of automation, I have already created `Ansible` playbooks and roles for setting up Consul. I have also created a new VPC CloudFormation template that, apart from creating all VPC parts, also creates a cluster of three Consul servers in AutoScaling group for our default VPC layout.