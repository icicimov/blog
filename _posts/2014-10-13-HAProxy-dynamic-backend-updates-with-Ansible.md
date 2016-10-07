---
type: posts
header:
  teaser: '4940499208_b79b77fb0a_z.jpg'
title: 'HAProxy dynamic backend updates with Ansible'
categories: 
  - DevOps
tags: [aws, ansible, infrastructure]
---

Due to some ELB limitations that did not play well with our user case like limited session timeout to 17 minutes, lack of multizone balancing, url rewriting to mention few, we are using HAproxy to front our application servers. Dropping ELB means loosing the best feature it provides and that is detection of backend changes. Because of this we had to come up with a solution to this problem and one way of doing it was using Ansible.

On the Ansible server we have the following playbook:

```
---
# USAGE: ansible-playbook ec2_haproxy_update.yml --extra-vars '{"hosts":"tag_Environment_staging", "region":"ap-southeast-2"}'

- name: create the backends group
  hosts: '{{ hosts }}'
  connection: local
  serial: 1
  gather_facts: no
  tasks:
  - add_host: hostname={{ ec2_private_dns_name|replace('.' + region + '.compute.internal', "") }} groupname=backends server_name={{ ec2_private_dns_name }}
    when: ec2_tag_Type is defined and ec2_tag_Type == "tomcat"
  - add_host: hostname={{ ec2_private_ip_address }} groupname=haproxy server_name={{ ec2_private_dns_name }}
    when: ec2_tag_Type is defined and ec2_tag_Type == "haproxy"    

- hosts: haproxy 
  remote_user: <some-sudo-user>
  sudo: true 
  gather_facts: true
  handlers:
    - include: roles/haproxy/handlers/main.yml
  tasks:
  - name: copy the config file over
    template: src=roles/haproxy/templates/hap-config-ssl-termination.j2 dest=/tmp/haproxy.cfg

  - name: calculate md5 of the temp file
    stat: path=/tmp/haproxy.cfg
    register: temp_haproxy_stat

  - name: calculate md5 of current config file
    stat: path=/etc/haproxy/haproxy.cfg
    register: current_haproxy_stat

  - name: check for changes
    command: test {{ temp_haproxy_stat.stat.md5 }} = {{ current_haproxy_stat.stat.md5 }}
    register: haproxy_check
    changed_when: "haproxy_check.rc != 0"
    failed_when: haproxy_check.stderr

  - name: install the new config file if there was a change and reload haproxy
    template: src=roles/haproxy/templates/hap-config-ssl-termination.j2 dest=/etc/haproxy/haproxy.cfg backup=yes owner=root group=root mode=0644
    when: haproxy_check.changed
    notify:
      - reload haproxy
```

which when launched like:

```
$ ansible-playbook ec2_haproxy_update.yml --extra-vars '{"hosts":"tag_Environment_staging","region":"ap-southeast-2"}'
```

does the following:

* Runs a locally executed task that based on the region and our environment tag, creates 2 groups of hosts, `backends` for the application backends and `haproxy` for the haproxy servers
* Populates the haproxy configuration template with the hosts found in the `backends` group and copies it over under `/tmp/haproxy.cfg` on each haproxy server
* Calculates the MD5 checksum of the new and the current config file and if they differ copies the new one over
* Reloads the HAProxy service to activate the new config file

 The relevant part of the HAProxy configuration template looks like this:

```
{% for backend in groups['backends'] %}
    server {{ backend }} {{ backend }}:8080 check observe layer7
{% endfor %}
```
and the haproxy reload hook as this:

```
- name: reload haproxy
  shell: 'iptables -I INPUT -p tcp -m multiport --dports 80,443 --syn -j DROP; sleep 0.5; \
          /etc/init.d/haproxy reload; iptables -D INPUT -p tcp -m multiport --dports 80,443 --syn -j DROP'
```

which will make the client connections hang for very short time needed for the reload.

Puting this in a crontab provides for central management of the haproxy servers for each of our environments.