---
type: posts
header:
  teaser: 'Ansible.png'
title: 'DNS issues with AWS EC2 images and systemd-resolved'
categories: 
  - DevOps
tags: [ansible]
date: 2020-8-14
excerpt: "Some DNS issues I faced with latest EC2 Ubuntu images and systemd-resolved."
---


## PROBLEM 1: Wrong DHCP option

The simptom is corrupted `resolv.conf` file in the EC2 Bionic images:

```bash
...
search eu-west-2.compute.internal032my.domain.com032consul
```

Notice the extraneous `032` character between the domains (which is encoded space). 

This problem is caused by AWS pushing a wrong DHCP option in case when the VPC has multiple DNS domains setup impacting the EC2 Ubuntu images using netplan's DHCP client and `systemd-resolved`. AWS does not conform to the RFC2132 and sends wrong DHCP option. In case of multiple domain names the `DHCP Option 119` [https://tools.ietf.org/search/rfc3397#section-2](https://tools.ietf.org/search/rfc3397#section-2) needs to be sent to the clients instead of packing them all inside the `DHCP Option 15` [https://tools.ietf.org/html/rfc2132#section-3.17](https://tools.ietf.org/html/rfc2132#section-3.17) as AWS does.

Checked and confirmed myself with `dhcpdump`, indeed AWS is still sending multiple domains via `Option 15` (Domainname):

```bash
---------------------------------------------------------------------------
  TIME: 2020-08-13 00:58:52.630
    IP: 10.233.0.1 (6:4c:b8:c2:2a:5a) > 10.233.0.71 (6:38:f3:17:15:9a)
    OP: 2 (BOOTPREPLY)
 HTYPE: 1 (Ethernet)
  HLEN: 6
  HOPS: 0
   XID: f37a8d72
  SECS: 0
 FLAGS: 0
CIADDR: 0.0.0.0
YIADDR: 10.233.0.71
SIADDR: 0.0.0.0
GIADDR: 0.0.0.0
CHADDR: 06:38:f3:17:15:9a:00:00:00:00:00:00:00:00:00:00
 SNAME: .
 FNAME: .
OPTION:  53 (  1) DHCP message type         5 (DHCPACK)
OPTION:  54 (  4) Server identifier         10.233.0.1
OPTION:  51 (  4) IP address leasetime      3600 (60m)
OPTION:   1 (  4) Subnet mask               255.255.255.0
OPTION:  28 (  4) Broadcast address         10.233.0.255
OPTION:   3 (  4) Routers                   10.233.0.1
OPTION:  15 ( 47) Domainname                eu-west-2.compute.internal my.domain.com consul
OPTION:   6 (  8) DNS server                169.254.169.253,10.233.0.2
OPTION:  12 ( 14) Host name                 ip-10-233-0-71
OPTION:  26 (  2) Interface MTU             9001
---------------------------------------------------------------------------
```

in which case as per the RFCs the whole string gets taken as a single domain which, again according to the RFCs, should not have a space in it. Hence, netplan's DHCP client does the right thing and replaces all spaces with `032`.

```bash
root@ip-10-233-0-71:~# netplan ip leases ens5
# This is private data. Do not parse.
ADDRESS=10.233.0.71
NETMASK=255.255.255.0
ROUTER=10.233.0.1
SERVER_ADDRESS=10.233.0.1
MTU=9001
T1=1800
T2=3150
LIFETIME=3600
DNS=169.254.169.253 10.233.0.2
DOMAINNAME=eu-west-2.compute.internal\032my.domain.com\032consul
HOSTNAME=ip-10-233-0-71
CLIENTID=ffed10bdb800020000ab11a7199769127ead09
```

In this particular case this is what the AWS DHCP should send according to the RFCs:

```
OPTION:  15  ( 26) Domainname     eu-west-2.compute.internal
OPTION:  119 ( 47) Domain Search  eu-west-2.compute.internal my.domain.com consul
```

The `Option 15` MUST be a single string with no spaces, no question about it. Till now we've been probably lucky that non RFC conformant clients have been parsing the DHCP reply.

We use Ansible for provisioning and to fix this I have created the following play:

```yaml
# USAGE: 
#  ansible-playbook -i <inventory> netplan.yml -e "playhosts=<server-group> region=eu-west-2 enc_env=<domain>"
---
- hosts: '{{ playhosts }}'
  gather_facts: true
  become: true
  vars:
   netplan_dns_fix: |-
     dhcp4-overrides:
         use-domains: false
     nameservers:
         search: [{{ region }}.compute.internal, {{ enc_env|lower }}.domain.com, consul]
  handlers:
    - name: netplan apply
      command: netplan apply
  tasks:
   # bugreport: https://bugs.launchpad.net/cloud-images/+bug/1791578
   - name: "Fix wrong AWS DHCP options issue in Bionic AMI and netplan/systemd-resolved"
     blockinfile:
       dest: "/etc/netplan/50-cloud-init.yaml"
       insertafter: 'set-name:'
       content: "{{ netplan_dns_fix | indent( width=12, indentfirst=True) }}"
       backup: true
       validate: 'netplan try -config-file %s'
     when: ansible_os_family == "Debian" and ansible_lsb.major_release|int >= 18
     notify: netplan apply
```

that runs on each of our Bionic servers during initial provisioning via user-data and modifies the `/etc/netplan/50-cloud-init.yaml` file like this:

```bash
$ cat /etc/netplan/50-cloud-init.yaml
# This file is generated from information provided by the datasource.  Changes
# to it will not persist across an instance reboot.  To disable cloud-init's
# network configuration capabilities, write a file
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:
# network: {config: disabled}
network:
    ethernets:
        ens5:
            dhcp4: true
            dhcp6: false
            match:
                macaddress: 0a:xx:xx:xx:xx:xx
            set-name: ens5
# BEGIN ANSIBLE MANAGED BLOCK
            dhcp4-overrides:
                use-domains: false
            nameservers:
                search: [eu-west-2.compute.internal, my.domain.com, consul]
# END ANSIBLE MANAGED BLOCK
    version: 2
```

which in turn makes the `resolv.conf` file render properly.

```bash
...
search eu-west-2.compute.internal my.domain.com consul
```

Not perfect since `domain.com` and `consul` are kinda hardcoded but we use same options in all our VPCs so we can get away with it. And to give little bit of background, `<name>.domain.com` is internal Route53 DNS zone we create per VPC that is used for internal resolution. Each EC2 instance in a VPC registers itself in this domain during initial provisioning thus making itself available as `server.<name>.domain.com` for its internal clients. It also makes possible for us to SSH to servers in private subnets via a Jump host used as ssh proxy using just the short (user friendly) `server` name and some ssh client config trickery.

## PROBLEM 2: Wrong DNS server(s) in Ansible facts

This problem is caused by Ansible not picking up the correct DNS servers in its facts. It reads the `/etc/resolv.conf` file, which is a link to `/run/systemd/resolve/stub-resolv.conf`, where it finds:

```
nameserver 127.0.0.53
```

for `systemd-reolved` enabled servers. Consequently when using the `{% raw %}{{ ansible_dns.nameservers }}{% endraw %}` fact in our templates to extract the DNS server for the remote host we endup with the following in the `/etc/ipsec.conf` config file for our VPN:

```
version 2.0

config setup
  strictcrlpolicy=no
  uniqueids=yes
  cachecrls=no

...

conn vpn-ikev2
  auto=add
  compress=no
  type=tunnel
  keyexchange=ikev2
...
  rightdns=127.0.0.53
```

thus pushing the `systemd-resolved` stub resolver to the clients which is obviously not good.

Given we have the following variable:

```yaml
systemdresolved_path: '/run/systemd/resolve/resolv.conf'
```

the Ansible code that picks up the correct DNS is:

```yaml
{% raw %}
# 18.04 dns server workaround
- slurp:
   src: "{{ systemdresolved_path }}"
  register: slurpfile
- set_fact:
   resolve_file: "{{ slurpfile['content'] | b64decode }}"
- set_fact:
   dnsnames: |
     {%- set names = [] -%}
     {%- for item in rf if "nameserver" in item -%}
       {%- do names.append(item.split(' ')[1]) -%}
     {%- endfor -%}
     {{ names }}
  vars:
    rf: "{{ resolve_file.splitlines() }}"
- set_fact:
   strongswan_dns_upstream: "{{ (ansible_distribution_major_version >= '18') | ternary(dnsnames, ansible_dns.nameservers) }}"
{% endraw %}
<the rest of the play here>
```

Now for the Ubuntu versions affected, which is 18.04+, we read the correct file, extract the DNS server(s) and store them in the `dnsnames` list. Then our template looks like: 

```
...
  rightdns={% if strongswan_dns_upstream|length > 0 %}{% for item in strongswan_dns_upstream %}{{ item }}{% if not loop.last %},{% endif %}{% endfor %}{% else %}8.8.8.8{% endif %}
```
which gives us:

```
  rightdns=172.31.0.2
```

as a result. Quick local test on Ubuntu-18.04+ host, create `test.yml`:

```yaml
{% raw %}
---
- hosts: 127.0.0.1
  connection: local
  gather_facts: true
  become: false 
  vars:
    systemdresolved_path: "/run/systemd/resolve/resolv.conf"
  tasks:
  - slurp:
     src: "{{ systemdresolved_path }}"
    register: slurpfile
  - set_fact:
     resolve_file: "{{ slurpfile['content'] | b64decode }}"
  - set_fact:
     dnsnames: |
       {%- set names = [] -%}
       {%- for item in rf if "nameserver" in item -%}
         {%- do names.append(item.split(' ')[1]) -%}
       {%- endfor -%}
       {{ names }}
    vars: 
      rf: "{{ resolve_file.splitlines() }}"
  - set_fact:
     dns_upstream: "{{ (ansible_distribution_major_version >= '18') | ternary(dnsnames, ansible_dns.nameservers) }}"
  - debug: var=dns_upstream
{% endraw %}
```

and execute:

```bash
$ echo 'localhost	server_name=local  ansible_connection=local' > local
$ ansible-playbook -i local test.yml
```
