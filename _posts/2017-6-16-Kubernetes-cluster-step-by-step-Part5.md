---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Kube-apiserver with Keepalived and HAProxy for HA'
categories: 
  - Kubernetes
tags: ['kubernetes', 'keepalived', 'haproxy']
date: 2017-6-16
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

# HAProxy and Keepalived for API High-Availability

## Keepalived

Keepalived will be responsible for the K8S Master VIP of `192.168.0.150`. It will assign it to one of the nodes that has healthy HAProxy running and in case that node or HAProxy crashes will move it to another healthy peer. In that way the K8S API will always stay available in the cluster. 

The content of the `/etc/keepalived/keepalived.conf` file on `k8s01` is: 

```
vrrp_script haproxy-check {
    script "killall -0 haproxy"
    interval 2
    weight 20
}
 
vrrp_instance haproxy-vip {
    state BACKUP
    priority 101
    interface eth0
    virtual_router_id 47
    advert_int 3
 
    unicast_src_ip 192.168.0.147 
    unicast_peer {
        192.168.0.148
        192.168.0.149 
    }
 
    virtual_ipaddress {
        192.168.0.150 
    }
 
    track_script {
        haproxy-check weight 20
    }
}
```

The file is practically same on `k8s02` and `k8s03` except for the IPs that are shuffled around.

## HAProxy

HAProxy will do health checks of the `kube-apiserver` on each of the nodes and load-balance the requests to the healthy instance(s) in the cluster. It will also make the K8S web UI (Dashboard) available on `192.168.0.150` to the members of the local LAN. 

It is configured as transparent SSL proxy in tcp mode. The relevant part of the config in `/etc/haproxy/haproxy.cfg`:

```
frontend k8s-api
  bind 192.168.0.150:443
  bind 127.0.0.1:443
  mode tcp
  option tcplog
  default_backend k8s-api

backend k8s-api
  mode tcp
  option tcplog
  option tcp-check
  balance roundrobin
  default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
  server k8s-api-1 192.168.0.147:6443 check
  server k8s-api-2 192.168.0.148:6443 check
  server k8s-api-3 192.168.0.149:6443 check
```

Obviously the above configuration expects the API server running on TCP port `6443` on each node which is what we use in the following configuration. The full version of the file is available [here]({{ site.baseurl }}/download/haproxy-k8s.cfg) for download.

# Kube-apiserver

## Option 1: Running as Systemd Service

This is the option I decided to go with. The service unit file:

```
cat << EOF > /lib/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
After=network.target etcd.service flanneld.service

[Service]
EnvironmentFile=-/var/lib/flanneld/subnet.env
#User=kube
ExecStart=/usr/local/bin/kube-apiserver \\
 --bind-address=0.0.0.0 \\
 --advertise_address=192.168.0.147 \\
 --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota \\
 --allow-privileged=true \\
 --anonymous-auth=false \\
 --apiserver-count=3 \\
 --authorization-mode=RBAC,AlwaysAllow \\
 --authorization-rbac-super-user=admin \\
 --basic-auth-file=/srv/kubernetes/basic_auth.csv \\
 --client-ca-file=/srv/kubernetes/ca.pem \\
 --etcd-servers=http://192.168.0.147:4001 \\
 --insecure-port=8080 \\
 --runtime-config=api/all=true,batch/v2alpha1=true,rbac.authorization.k8s.io/v1alpha1=true \\
 --secure-port=6443 \\
 --service-cluster-ip-range=100.65.0.0/24 \\
 --storage-backend=etcd2 \\
 --tls-cert-file=/srv/kubernetes/apiserver.pem \\
 --tls-private-key-file=/srv/kubernetes/apiserver-key.pem \\
 --tls-ca-file=/srv/kubernetes/ca.pem \\
 --kubelet-certificate-authority=/srv/kubernetes/ca.pem \\
 --token-auth-file=/srv/kubernetes/known_tokens.csv \\
 --portal-net=\${FLANNEL_NETWORK} \\
 --logtostderr=true \\
 --v=6
Restart=on-failure
Type=notify
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

After starting the service we can confirm we can gain access to the cluster: 

```
root@k8s01:~# kubectl get namespaces
NAME          STATUS    AGE
default       Active    18m
kube-public   Active    18m
kube-system   Active    18m

root@k8s01:~# kubectl cluster-info
Kubernetes master is running at https://k8s-api.virtual.local
```

and even check the certificate via openssl:

```
root@k8s01:~# openssl s_client -CApath /srv/kubernetes/ -showcerts -connect k8s-api.virtual.local:443
CONNECTED(00000003)
depth=0 CN = kube-apiserver
verify error:num=20:unable to get local issuer certificate
verify return:1
depth=0 CN = kube-apiserver
verify error:num=21:unable to verify the first certificate
verify return:1
---
Certificate chain
 0 s:/CN=kube-apiserver
   i:/CN=kube-ca
-----BEGIN CERTIFICATE-----
MIIDsTCCApmgAwIBAgIJANQRSdlqdPZVMA0GCSqGSIb3DQEBCwUAMBIxEDAOBgNV
...
EXTfJMOCdhOtEcE0SU118mmilVafM3VgR7+mE+0xrPXJxla++w==
-----END CERTIFICATE-----
---
Server certificate
subject=/CN=kube-apiserver
issuer=/CN=kube-ca
---
Acceptable client certificate CA names
/CN=kube-ca
---
...
```

Now to point all other K8S services internal to the cluster to the API, we need to create internal Service that points to the external IP of the API server:

```
# kube-apiserver-service.yml
apiVersion: v1
kind: Service
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  externalIPs:
  - 192.168.0.150
  ports:
  - port: 443
    protocol: TCP
  selector:
    name: kube-apiserver
  clusterIP: 100.64.0.1

root@k8s01:~# kubectl create -f kube-apiserver-service.yml
service "kube-apiserver" created

root@k8s01:~# kubectl get svc -n kube-system
NAME                   CLUSTER-IP      EXTERNAL-IP     PORT(S)         AGE
kube-apiserver         100.64.0.1      192.168.0.150   443/TCP         10s
kube-dns               100.64.0.10     <none>          53/UDP,53/TCP   1h
kubernetes-dashboard   100.64.235.53   <none>          80/TCP          17h
```

Then following `Iptables` rules and route need to be created on each host:

```
root@k8s01:~# iptables -t nat -A PREROUTING -s 100.64.0.0/15 -d 100.64.0.1/32 -p tcp -m tcp -j DNAT --to-destination 192.168.0.150
root@k8s01:~# iptables -t nat -A PREROUTING -s 100.64.0.0/15 -d 100.65.0.1/32 -p tcp -m tcp -j DNAT --to-destination 192.168.0.150
root@k8s01:~# ip route add 100.65.0.1/32 dev flannel.1 scope host
```

so the cluster pods can talk to the API server which is external and they see it as `100.65.0.1/32` (the first IP in the cluster service CIDR range).

## Option 2: Running as Kubernetes Pod

The [kube-apiserver.yml]({{ site.baseurl }}/download/kube-apiserver.yml) Manifest available below and for download. 

```
# /etc/kubernetes/manifests/kube-apiserver.yml
---
apiVersion: v1
kind: Pod
metadata:
  annotations:
    dns.alpha.kubernetes.io/internal: k8s-api.virtual.local
  creationTimestamp: null
  labels:
    k8s-app: kube-apiserver
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - /bin/sh
    - -c
    - /usr/local/bin/kube-apiserver --address=127.0.0.1 --admission-control=NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota
      --allow-privileged=true --anonymous-auth=false --apiserver-count=3 --authorization-mode=RBAC,AlwaysAllow
      --authorization-rbac-super-user=admin --basic-auth-file=/srv/kubernetes/basic_auth.csv
      --client-ca-file=/srv/kubernetes/ca.pem --etcd-servers-overrides=/events#http://127.0.0.1:4002
      --etcd-servers=http://127.0.0.1:4001 --insecure-port=8080 --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP,LegacyHostIP
      --runtime-config=api/all=true,batch/v2alpha1=true,rbac.authorization.k8s.io/v1alpha1=true
      --secure-port=443 --service-cluster-ip-range=100.65.0.0/24 --storage-backend=etcd2
      --tls-cert-file=/srv/kubernetes/apiserver.pem --tls-private-key-file=/srv/kubernetes/apiserver-key.pem
      --token-auth-file=/srv/kubernetes/known_tokens.csv --v=2 1>>/var/log/kube-apiserver.log
      2>&1
    image: gcr.io/google_containers/kube-apiserver:v1.6.7
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 8080
      initialDelaySeconds: 15
      timeoutSeconds: 15
    name: kube-apiserver
    ports:
    - containerPort: 443
      hostPort: 443
      name: https
    - containerPort: 8080
      hostPort: 8080
      name: local
    resources:
      requests:
        cpu: 150m
    volumeMounts:
    - mountPath: /etc/ssl
      name: etcssl
      readOnly: true
    - mountPath: /usr/share/ca-certificates
      name: cacertificates
      readOnly: true
    - mountPath: /srv/kubernetes
      name: srvkube
      readOnly: true
    - mountPath: /var/log/kube-apiserver.log
      name: logfile
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/ssl
    name: etcssl
  - hostPath:
      path: /usr/share/ca-certificates
    name: cacertificates
  - hostPath:
      path: /srv/kubernetes
    name: srvkube
  - hostPath:
      path: /var/log/kube-apiserver.log
    name: logfile
```

At the end, the image of HAProxy dashboard showing the Kube-api service load balancer:

[![Kube-api in HAProxy dashboard](/blog/images/k8s-haproxy-dashboard-traefik.png)](/blog/images/k8s-haproxy-dashboard-traefik.png "Kube-api in HAProxy dashboard")

{% include series.html %}
