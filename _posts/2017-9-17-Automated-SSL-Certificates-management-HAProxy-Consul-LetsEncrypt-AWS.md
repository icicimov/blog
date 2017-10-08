---
type: posts
header:
  teaser: 'lets-encrypt.jpg'
title: 'Automated SSL Certificates management with HAProxy, Consul and Lets Encrypt on AWS'
categories: 
  - DevOps
tags: ['letsencrypt', 'haproxy', 'consul', 'ssl', 'ocsp']
date: 2017-9-17
---

[Let's Encrypt](https://letsencrypt.org/) has quickly become a standard in obtaining and managing TLS certificates. It is a service provided by the [Internet Security Research Group (ISRG)](https://letsencrypt.org/isrg/) and it's a free, automated and open Certificate Authority (CA). No more paying thousands of dollars per year for a single (and usually overpriced) certificate and no more going through the never ending process of manual renewing with CA's (some of which often find them self in the centre of a security scandals). Let's Encrypt lets us automate all this process in highly secure fashion and get done with it in a matter of seconds without any human intervention at all.

Let's Encrypt has announced support for Wildcard Certificates coming in January 2018. It also doesn't support EV and OV certificates which is a limitation to consider before starting its implementation.

# The Process

So, all we need to do is create some automation on our side too. For a single server the process of obtaining and renewing a TLS certificate(s) is pretty straight forward: we register an account and fire up one of the compatible ACME clients ([Certbot](http://letsencrypt.readthedocs.io/en/latest/index.html) being one of most popular ones) that goes through the (one of the several) process of verification and installing the certificate. The certificate is then valid for 90 days after which period we have to go through the same process again. Which is pretty easy to automate, we just need a script that will fire up via cronjob lets say or systemd timer and we are done. But in production we usually have multiple servers that need the same certificate therefore we need some kind of centralized solution that will obtain and distribute the certificates across multiple clusters.

We are using [HAProxy](http://www.haproxy.org/) as TLS frontend and [Consul](https://www.consul.io/) (for service discovery and K/V store) across our infrastructure which makes it possible to come up with a Highly-Available, centralized and yet distributed TLS certificates management as shown in the below diagram:

![Lets Encrypt workflow](/blog/images/letsencrypt.png "Lets Encrypt workflow")

The work flow of how a TLS certificate is obtained and how it ends up on the target servers is described in the legend. Basically we have a central server that handles the requests with Let's Encrypt and then stores them in a Consul cluster for the VPC. The Consul client running on each of the frontends monitors the K/V certificate store and upon any change downloads and installs the certificates and gracefully (no hacks needed since version 1.7, see [Truly Seamless Reloads with HAProxy – No More Hacks!](https://www.haproxy.com/blog/truly-seamless-reloads-with-haproxy-no-more-hacks/)) reloads HAProxy.

# The Setup

Once the certificate is obtained on the central server the way we distribute them across our infrastructure is a matter of choice. We can use a Configuration Manager like [Ansible](https://www.ansible.com/) (which is our CM of choice for everyday DevOps tasks) but I decided to go with Consul since it provides me with an API for the task meaning I don't need Ansible (and its prerequisites Python packages) installed and I can do it from any server using simple tool like CuRL. It also means that any time a new HAProxy server gets launched in the VPC it will automatically pick up the needed certificates from the Consul store.

## Our Central LE Manager

We start with our central LE LE Manager server. First install LE:

```
# git clone https://github.com/letsencrypt/letsencrypt /opt/letsencrypt
# mkdir -p /etc/letsencrypt/{live,archive,keys}
```

and prepare the target directory for certificates store:

```
# mkdir -p -m 0740 /etc/ssl/private/le
# chown root:ssl-cert /etc/ssl/private/le
```

The [letsencrypt-get-cert.sh]({{ site.baseurl }}/download/letsencrypt-get-cert.sh) then takes care of obtaining and renewing certificates. We initiate it like this:

```
# bash letsencrypt-get-cert.sh some.server.domain.tld www.some.server.domain.tld [...]
```

and include as many domains (up to 100 are supported) as we need in the arguments list, they will be included in the SAN of the certificate. For example:

```
# bash letsencrypt-get-cert.sh test4.uk.lon.encompasshost.com www.test4.uk.lon.encompasshost.com
```

There is really only one line executed in the script that does the whole job:

```
$LE_TOOL --non-interactive --no-bootstrap --no-self-upgrade --no-eff-email --staple-ocsp --agree-tos --renew-by-default --standalone --post-hook "cat $LE_OUTPUT/$1/fullchain.pem $LE_OUTPUT/$1/privkey.pem > ${SSL_DIR}/${1}.crt && /usr/local/bin/letsencrypt-update-consul.sh ${1}.crt" --preferred-challenges http --http-01-port 9876 certonly $DOMAINS $MAIL
```

It basically launches the LE client that ends the certificate request and opens a socket on an advertised port (in this case TCP port 9876) waiting for the LE challenge which we set to be of type `http-01` (you can read here about [LE challenge types](http://letsencrypt.readthedocs.io/en/latest/challenges.html)). When done it invokes the second script [letsencrypt-update-consul.sh]({{ site.baseurl }}/download/letsencrypt-update-consul.sh) via a post-hook that takes care of putting the certificate into Consul K/V storage. This script base64 encodes the certificate (very important so the cert doesn't get mangled when saved in the K/V pair) and executes a secure (HTTPS) REST API call via CuR:

```
curl -ksSnL -X PUT -d @/tmp/tmp.crt --key ${AUTH_CERTS_PATH}/consul.key \
--cacert ${AUTH_CERTS_PATH}/consul-cacert.pem --cert ${AUTH_CERTS_PATH}/consul.pem \
"${ENC_CONSUL_PROTO}://${CONSUL}:${ENC_CONSUL_PORT}/v1/kv/le/certs/${1}"
```

to the Consul client exposed on the Bastion server. The access to it is for one fire-walled via SG (Security Group) to allow access from our central LE Manager server only and two it only accepts client connections that are authenticated via SSL certificates for added security (the certs/keys referenced in the command above). These need to be secured with appropriate access rights on file system level. As we can tell from the above API call the certs are stored as `le/certs/<domain-name>` key in Consul. This script also sends emails with info about the certificate that got updated.

### Renewing the Certificates

The [letsencrypt-check-certs.sh]({{ site.baseurl }}/download/letsencrypt-check-certs.sh) script running as cron job:

```
xx xx * * * /usr/local/bin/letsencrypt-check-certs.sh
```

takes care of this. It checks if any of the certificates `/etc/ssl/private/*.crt` have 30 days or less (as recommended by LE) till expiration and invokes the above get-cert script for those that do.

## Consul Agent Setup on the Bastion Server

The Bastion server is the only access point (apart for the frontend HAProxy load-balancers of course) into our VPC. This is the Consul agent config file `/etc/consul.d/client/config-https.json` that makes sure it listens on TCP port 8765 and be accessible from outside the VPC:

```
{
    "addresses": {
      "https": "0.0.0.0"
    },
    "ports": {
      "https": 8765
    }
}
```

and the settings in the main agent's config `/etc/consul.d/client/config.json`:

```
{
    "server": false,
    "leave_on_terminate": true,
    "rejoin_after_leave": true,
    "datacenter": "DC-TEST",
    "data_dir": "/var/consul",
    "encrypt": "XXXXXXXXXXXXXXXXXXXXXXXX",
    "ca_file": "/etc/consul.d/ssl/cacert.pem",
    "cert_file": "/etc/consul.d/ssl/consul.pem",
    "key_file": "/etc/consul.d/ssl/consul.key",
    "verify_incoming_rpc": true,
    "verify_incoming_https": true,
    "verify_outgoing": true,
    "enable_script_checks": true,
    "disable_host_node_id": false,
    "log_level": "INFO",
    "enable_syslog": true,
    "dns_config": {
       "enable_truncate": true,
       "allow_stale": true
    },
    "start_join": ["10.99.3.184", "10.99.2.254", "10.99.2.217"]
} 
```

make sure all traffic is encrypted and authorized via SSL client certificates.

## HAProxy Servers Setup

We can split this in the following parts.

### HAProxy

The first part of the setup is the HAProxy configuration itself. The relevant parts of the configuration in `/etc/haproxy/haproxy.cfg` is given below:

```
[...]
frontend fe_web
    bind *:80
    bind *:443 ssl crt /etc/haproxy/ssl.d/ no-sslv3 ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA...
    http-request redirect scheme https if !{ ssl_fc }
    [...]
    # LetsEncrypt challenge request
    acl letsencrypt-request path_beg -i /.well-known/acme-challenge/
    use_backend letsencrypt if letsencrypt-request

backend letsencrypt
    mode http
    server letsencrypt manager.encompasshost.com:9876
[...]
```

First we make sure it loads multiple certificates by pointing our main frontend to the directory `/etc/haproxy/ssl.d/` where the certs are installed. Then we send any incoming LE `http-01` type challenges for standalone mode that have path that starts with `/.well-known/acme-challenge/` to the letsencrypt backend, which in turn reverse-proxies the call to our LE Manager server where the LE client listens for the challenge on TCP port 9876 as explained before.

### OCSP Stapling

The OCSP stapling improves the SSL performance by cutting down the time to establish the SSL connection. The server attaches (staples) the OCSP answer to the public key which saves the client from additional step of going to the CA authority OCSP server to check for certificate validity. Instead it has it sent by the server during the SSL handshake process. The OCSP stapling is also something that Let's Encrypt asks from its customers to provide in order to reduce the load on their servers.

The script [ocsp_update.sh]({{ site.baseurl }}/download/ocsp_update.sh) gets initiated on daily bases and takes care of the process. It gets the OCSP response for each of the certificates under `/etc/haproxy/ssl.d/` and gracefully reloads HAProxy. The script makes assumption that he certificates have `.crt` suffix which is something we have adopted as standard for our certificates.

### Consul

This part of the setup takes care of fetching the certificates from the Consul store, installing them under the HAProxy's SSL directory `/etc/haproxy/ssl.d/` and reloading the HAProxy service. The watcher in the Consul agent setup in the `/etc/consul.d/client/haproxy.json` file:

```
{
    "service": {
        "name": "haproxy",
         [...]
    },
    "watches": [
      {
        "type": "keyprefix",
        "prefix": "le/certs/",
        "handler": "sudo /usr/local/bin/haproxy-consul-certs-handler.sh"
      }
    ]
}
```

monitors the K/V keys under `le/certs/` in Consul and upon a change i.e. new or updated certificate, triggers the [haproxy-consul-certs-handler.sh]({{ site.baseurl }}/download/haproxy-consul-certs-handler.sh) script. The main part of this script:

```
for cert in $(consul kv get -recurse -keys le/certs/)
do
    consul kv get le/certs/${cert##*/} | base64 -d > ${HAP_SSL_DIR}/${cert##*/} || FAIL=1
done
```

uses the Consul's `kv` CLI to get the certificates, `base64` decode and install them for HAProxy. Then a simple service reload does the update. The script also sends emails with info about the servers the HAP got reloaded on.

# Conclusion

Let's Encrypt provides for free and easy certificate management and automation. We have shown above how Consul, HAProxy and handful of scripts can extend this process to whole infrastructure distributed across many VPCs in AWS.

The image below shows the LE certificates stored in the Consul K/V store for the TEST Data Center (Cluster).

[![Consul dashboard](/blog/images/letsencrypt-consul.png)](/blog/images/letsencrypt-consul.png "Consul dashboard")