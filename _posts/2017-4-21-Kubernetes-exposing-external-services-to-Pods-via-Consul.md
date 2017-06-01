---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes - Exposing External Services to Pods via Consul'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers]
date: 2017-4-21
series: "Kubernetes Cluster in AWS"
---

Using Ingresses and Services of various types we can expose the k8s cluster services for use outside the cluster. Now we need to do the opposite, let our Pods know about other services running in our VPC they can talk to.

This article [Configuring Private DNS Zones and Upstream Nameservers in Kubernetes](http://blog.kubernetes.io/2017/04/configuring-private-dns-zones-upstream-nameservers-kubernetes.html) announced that in Kubernetes-1.6 kube-dns adds support for configurable private DNS zones (often called `stub domains`) and external upstream DNS nameservers. This makes it possible for us to expose the k8s external services to the Pods via Consul which we have running in each of our VPC's for the purpose of service discovery.

## Consul servers setup

The only change we need to make here is install and configure dnsmasq to listen on TCP/UDP port 53 and forward the requests for the `.consul` domain to the local consul service on port 8600:

```
# aptitude install -y dnsmasq
 
# vi /etc/dnsmasq.d/10-consul
server=/.consul/127.0.0.1#8600
server=/eu-west-1.compute.internal/10.99.0.2
 
# service dnsmasq force-reload
```

and make sure the TCP/UDP port 53 is opened for access internally to the VPC CIDR.

## k8s DNS setup

Create the following YAML file and create the resource:

```
$ vi kube-dns-consul-stubdomain.yml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"consul": ["10.99.3.146","10.99.4.35","10.99.5.11"]}
 
$ kubectl create -f kube-dns-consul-stubdomain.yml
```

This should be also possible but haven't tested (was recently committed to master):

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
data:
  stubDomains: |
    {"consul": ["consula.my.domain.internal","consulb.my.domain.internal","consulc.my.domain.internal"]}
```

which is better option then providing the IP's of the consul servers since each of them can get replaced with a new one in case of issue in which case the IP will change but the instance will take over the existing DNS record (courtesy of our Terraform user-data setup during VPC provisioning).

Now find the kube-dns pods and check the logs:

```
$ kubectl get pods -l k8s-app=kube-dns -n kube-system
NAME                        READY     STATUS    RESTARTS   AGE
kube-dns-1321724180-1dnnl   3/3       Running   0          2d
kube-dns-1321724180-7q35q   3/3       Running   6          2d
 
$ kubectl logs -f kube-dns-1321724180-1dnnl -c dnsmasq -n kube-system
[...]
I0601 06:51:50.408924       1 nanny.go:108] dnsmasq[14]: using nameserver 10.99.5.11#53 for domain consul
I0601 06:51:50.408932       1 nanny.go:108] dnsmasq[14]: using nameserver 10.99.4.35#53 for domain consul
I0601 06:51:50.408938       1 nanny.go:108] dnsmasq[14]: using nameserver 10.99.3.146#53 for domain consul
```

We can see the `dnsmasq sidecar` applying the update. Test the new DNS `DomainStub`:

```
$ kubectl run -i --tty --image busybox dns-test --restart=Never --rm /bin/sh
If you don't see a command prompt, try pressing enter.
 
/ # nslookup activemq.service.consul
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local

Name:      activemq.service.consul
Address 1: 10.99.5.19 ip-10-99-5-19.eu-west-1.compute.internal
Address 2: 10.99.3.222 ip-10-99-3-222.eu-west-1.compute.internal
 
/ # nslookup encompassdb.service.consul
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local

Name:      encompassdb.service.consul
Address 1: 10.99.5.178 ip-10-99-5-178.eu-west-1.compute.internal
Address 2: 10.99.4.30 ip-10-99-4-30.eu-west-1.compute.internal
Address 3: 10.99.3.251 ip-10-99-3-251.eu-west-1.compute.internal
 
/ # nslookup glusterfs.service.consul
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local

Name:      glusterfs.service.consul
Address 1: 10.99.5.91 ip-10-99-5-91.eu-west-1.compute.internal
Address 2: 10.99.4.161 ip-10-99-4-161.eu-west-1.compute.internal
Address 3: 10.99.3.216 ip-10-99-3-216.eu-west-1.compute.internal
/ #
```

and we can see our other services running in the VPC are now resolvable by the pods in the k8s cluster and can be referenced by their DNS names.

{% include series.html %}