---
type: posts
header:
  teaser: 'images.jpg'
title: 'Encrypted DNS with BIND and DNSCrypt'
categories: 
  - Server
tags: ['dns']
date: 2019-06-23
---

[DNSCrypt](https://dnscrypt.info/) is a protocol that authenticates communications between a DNS client and a DNS resolver. It prevents DNS spoofing. It uses cryptographic signatures to verify that responses originate from the chosen DNS resolver and haven’t been tampered with. It is an open specification, with free and open source reference implementations, and it is not affiliated with any company nor organization. Free DNSCrypt-enabled resolvers are available all over the world.

## DNSCrypt setup

The project provides the [DNSCrypt proxy](https://github.com/DNSCrypt/dnscrypt-proxy) as source code and pre-built binaries for most operating systems and architectures.

```bash
root@dns:/opt# wget https://github.com/jedisct1/dnscrypt-proxy/releases/download/2.0.16/dnscrypt-proxy-linux_x86_64-2.0.16.tar.gz
root@dns:/opt# tar -xzvf dnscrypt-proxy-linux_x86_64-2.0.16.tar.gz
root@dns:/opt# mv linux-x86_64/ dnscrypt-proxy
root@dns:/opt# cd dnscrypt-proxy/
root@dns:/opt/dnscrypt-proxy# ls -la
total 7808
drwxr-xr-x 2 2000 2000    4096 Jun 22 12:29 .
drwxr-xr-x 6 root root    4096 Aug 16  2018 ..
-rwxr-xr-x 1 2000 2000 7884928 Jul 10  2018 dnscrypt-proxy
-rw-r--r-- 1 root root   14628 Aug 16  2018 dnscrypt-proxy.toml
-rw-r--r-- 1 2000 2000     841 Jul 10  2018 example-blacklist.txt
-rw-r--r-- 1 2000 2000     714 Jul 10  2018 example-cloaking-rules.txt
-rw-r--r-- 1 2000 2000   14593 Jul 10  2018 example-dnscrypt-proxy.toml
-rw-r--r-- 1 2000 2000     600 Jul 10  2018 example-forwarding-rules.txt
-rw-r--r-- 1 2000 2000     723 Jul 10  2018 example-whitelist.txt
-rw-r--r-- 1 2000 2000     818 Jul 10  2018 LICENSE
-rw-r--r-- 1 root root   39140 Jun 22 12:29 public-resolvers.md
-rw-r--r-- 1 root root     307 Jun 22 12:29 public-resolvers.md.minisig
```

Create the configuration file and setup the proxy to listen on `127.0.2.1:53`:

```bash
root@dns:/opt/dnscrypt-proxy# cp example-dnscrypt-proxy.toml dnscrypt-proxy.toml
root@dns:/opt/dnscrypt-proxy# vi dnscrypt-proxy.toml
[...]
#listen_addresses = ['127.0.0.1:53', '[::1]:53']
listen_addresses = ['127.0.2.1:53']
[...]
tls_cipher_suite = [52392, 49199]
[...]
```

Do a test run and check if it can start properly:

```bash
root@dns:/opt/dnscrypt-proxy# ./dnscrypt-proxy -list
[2019-06-23 12:02:22] [NOTICE] Source [public-resolvers.md] loaded
doh.appliedprivacy.net
arvind-io
bottlepost-dns-nl
charis
cloudflare
cpunks-ru
cs-ch
cs-swe
cs-nl
cs-nl2
cs-fi
cs-pl
cs-dk
cs-it
cs-fr
cs-fr2
cs-pt
cs-ro
cs-mo
cs-lv
cs-uk
cs-de
cs-de2
cs-ca
cs-ca2
cs-usny
cs-usil
cs-usnv
cs-uswa
cs-usdc
cs-ustx
cs-usga
cs-usnc
cs-usca
cs-usor
d0wn-is-ns2
d0wn-tz-ns1
de.dnsmaschine.net
dnscrypt.ca-1
dnscrypt.ca-2
dnscrypt.eu-dk
dnscrypt.eu-nl
dnscrypt.me
dnscrypt.nl-ns0
dnscrypt.nl-ns0-doh
dnscrypt.uk-ipv4
doh-crypto-sx
doh-ibksturm
encrypt-town
ev-va
ev-to
freetsa.org
gridns-jp
gridns-sg
ibksturm
ipredator
opennic-ethservices
opennic-ethservices2
opennic-luggs
opennic-luggs2
powerdns-doh
publicarray-au
publicarray-au-doh
publicarray-au2
publicarray-au2-doh
quad101
quad9-dnscrypt-ip4-nofilter-pri
quad9-dnscrypt-ip4-nofilter-alt
quad9-doh-ip4-nofilter-pri
quad9-doh-ip4-nofilter-alt
qualityology.com
scaleway-fr
securedns
securedns-doh
soltysiak
suami
trashvpn.de
ventricle.us
opennic-R4SAS

root@dns:/opt/dnscrypt-proxy# ./dnscrypt-proxy -check
[2019-06-23 12:02:32] [NOTICE] Source [public-resolvers.md] loaded
[2019-06-23 12:02:32] [NOTICE] Configuration successfully checked

root@dns:/opt/dnscrypt-proxy# ./dnscrypt-proxy -resolve cloudflare-dns.com
Resolving [cloudflare-dns.com]

Domain exists:  yes, 3 name servers found
Canonical name: cloudflare-dns.com.
IP addresses:   104.16.249.249, 104.16.248.249, 2606:4700::6810:f8f9, 2606:4700::6810:f9f9
TXT records:    v=spf1 include:no-ip.com -all
Resolver IP:    220.233.0.34 (kolanut2.exetel.com.au.)
```

To install as service we run:

```bash
root@dns:/opt/dnscrypt-proxy# ./dnscrypt-proxy -service install
[2019-06-23 12:02:58] [NOTICE] Source [public-resolvers.md] loaded
[2019-06-23 12:02:58] [NOTICE] dnscrypt-proxy 2.0.16
[2019-06-23 12:02:59] [NOTICE] Installed as a service. Use `-service start` to start
```

On Ubuntu 14.04:

```bash
root@dns:/opt/dnscrypt-proxy# cat /etc/init/dnscrypt-proxy.conf
# Encrypted/authenticated DNS proxy

description    "DNSCrypt client proxy"

kill signal INT

chdir /opt/dnscrypt-proxy
start on filesystem or runlevel [2345]
stop on runlevel [!2345]

respawn
respawn limit 10 5
umask 022

console none

pre-start script
    test -x /opt/dnscrypt-proxy/dnscrypt-proxy || { stop; exit 0; }
end script

# Start
exec /opt/dnscrypt-proxy/dnscrypt-proxy
```

On Ubuntu-16.04:

```bash
root@dns:/opt/dnscrypt-proxy# systemctl cat dnscrypt-proxy.service
# /etc/systemd/system/dnscrypt-proxy.service 
[Unit]
Description=Encrypted/authenticated DNS proxy
ConditionFileIsExecutable=/opt/dnscrypt-proxy/dnscrypt-proxy

[Service]
StartLimitInterval=5
StartLimitBurst=10
ExecStart=/opt/dnscrypt-proxy/dnscrypt-proxy

WorkingDirectory=/opt/dnscrypt-proxy

Restart=always
RestartSec=120
EnvironmentFile=-/etc/sysconfig/dnscrypt-proxy

[Install]
WantedBy=multi-user.target
```

Testing the service startup:

```bash
root@dns:/opt/dnscrypt-proxy# ./dnscrypt-proxy -service start
[2019-06-23 12:04:04] [NOTICE] Source [public-resolvers.md] loaded
[2019-06-23 12:04:04] [NOTICE] dnscrypt-proxy 2.0.16
[2019-06-23 12:04:05] [NOTICE] Service started

root@dns:/opt/dnscrypt-proxy# systemctl status dnscrypt-proxy.service 
 dnscrypt-proxy.service - Encrypted/authenticated DNS proxy
   Loaded: loaded (/etc/systemd/system/dnscrypt-proxy.service; enabled; vendor preset: enabled)
   Active: active (running) since Sun 2019-06-23 12:04:04 AEST; 39s ago
 Main PID: 25687 (dnscrypt-proxy)
   CGroup: /system.slice/dnscrypt-proxy.service
           └─25687 /opt/dnscrypt-proxy/dnscrypt-proxy

Jun 23 12:04:40 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:40] [NOTICE] [scaleway-fr] OK (crypto v2) - rtt: 304ms
Jun 23 12:04:40 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:40] [NOTICE] [securedns] OK (crypto v1) - rtt: 303ms
Jun 23 12:04:42 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:42] [NOTICE] [securedns-doh] OK (DoH) - rtt: 305ms
Jun 23 12:04:42 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:42] [NOTICE] [soltysiak] OK (crypto v1) - rtt: 330ms
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] [suami] OK (crypto v2) - rtt: 333ms
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] [trashvpn.de] OK (crypto v2) - rtt: 329ms
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] [ventricle.us] OK (crypto v2) - rtt: 227ms
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] [opennic-R4SAS] OK (crypto v2) - rtt: 301ms
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] Server with the lowest initial latency: quad9-dnscrypt-ip4-nofilter-pri (rtt: 9ms)
Jun 23 12:04:43 dns dnscrypt-proxy[25687]: [2019-06-23 12:04:43] [NOTICE] dnscrypt-proxy is ready - live servers: 72
```

We can go and enable it now:

```bash
root@dns:/opt/dnscrypt-proxy# systemctl enable dnscrypt-proxy.service
root@dns:/opt/dnscrypt-proxy# systemctl is-enabled dnscrypt-proxy.service
enabled
```

## BIND setup

Now tell BIND to forward to DNSCrypt, edit the `/etc/bind/named.conf.options` file and forward the traffic to `127.0.2.1` where our `dnscrypt-proxy` is listening:

```bash
options {
	directory "/var/cache/bind";

	// If there is a firewall between you and nameservers you want
	// to talk to, you may need to fix the firewall to allow multiple
	// ports to talk.  See http://www.kb.cert.org/vuls/id/800113

	// If your ISP provided one or more IP addresses for stable 
	// nameservers, you probably want to use them as forwarders.  
	// Uncomment the following block, and insert the addresses replacing 
	// the all-0's placeholder.

	// forwarders {
	// 	0.0.0.0;
	// };

	//========================================================================
	// If BIND logs error messages about the root key being expired,
	// you will need to update your keys.  See https://www.isc.org/bind-keys
	//========================================================================

    version "get lost";
    allow-transfer {"none";};
    allow-query { any; };
    minimal-responses yes;

    // Forward the queries I can't resolve (domains not mine)
    forwarders {
		// DNSCrypt
        127.0.2.1;

		//forward only;
        // CloudFlare and Google
        //1.1.1.1;
        //8.8.8.8;
    };

	dnssec-validation auto;
	// look for dnssec keys here:
	key-directory "/etc/bind/keys";
	// only sign DNSKEY with KSK
	dnssec-dnskey-kskonly yes;
	// expiration time 21d, refresh period 16d
	sig-validity-interval 21 16;

	auth-nxdomain no;    # conform to RFC1035
	listen-on-v6 { any; };

	edns-udp-size 4096;
};
```

and reload the service:

```bash
root@dns:/opt/dnscrypt-proxy# rndc reload
```

## Testing if DNSCrypt proxy is in use

Testing is very simple, since my local BIND is my primary DNS on the home LAN I stop the `dnscrypt-proxy` and confirm I can not reach any public website.
