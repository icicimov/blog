---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Route53 Zone export'
categories: 
  - DevOps
tags: [aws]
date: 2016-4-6
---

You need to have your local system ready for AWS access.

Find the Zone ID we want to export/backup:

```
$ aws route53 list-hosted-zones-by-name --dns-name domain.com --query 'HostedZones[0].Id'
"/hostedzone/ZXXXXXXXXXXXXI"
```

Export the Zone into Route53 and BIND compatible file:
$ cli53 export --full ZXXXXXXXXXXXXI > ~/backups/route53/zone_file_domain_com

The `cli53` command line tool has been obtained as follows:

```
$ wget https://github.com/barnybug/cli53/releases/download/0.7.2/cli53-linux-amd64
$ sudo mv cli53-linux-amd64 /usr/local/bin/cli53
$ sudo chmod +x /usr/local/bin/cli53
```