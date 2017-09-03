---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Kubelet, Kube-scheduler and Kube-controller-manager'
categories: 
  - Kubernetes
tags: ['kubernetes']
date: 2017-6-17
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

# Kubelet

First make sure the Kubeconfig file for the service is present (it was generated in Step2):

```
# /var/lib/kubelet/kubeconfig
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRV....
    server: https://k8s-api.virtual.local
  name: k8s.virtual.local
contexts:
- context:
    cluster: k8s.virtual.local
    user: kubelet
  name: k8s.virtual.local
current-context: k8s.virtual.local
kind: Config
preferences: {}
users:
- name: kubelet
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJ....
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJ....
    token: eEruMaNmve4IPTwgH5kP3wB21BhZWgZP
```

## Option 1: Running as Systemd Service

Create a unit file:

```
# /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet Server
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service

[Service]
EnvironmentFile=/etc/sysconfig/kubelet
ExecStart=/usr/local/bin/kubelet "$DAEMON_ARGS"
Restart=always
RestartSec=2s
StartLimitInterval=0
KillMode=process

[Install]
WantedBy=multi-user.target
```

and the configuration file the above unit will load:

```
# /etc/sysconfig/kubelet
DAEMON_ARGS="--v=2 --non-masquerade-cidr=100.64.0.0/15 --allow-privileged=true --enable-custom-metrics=true --babysit-daemons=true --cgroup-root=/ --api-servers=https://k8s-api.virtual.local --cluster-dns=100.64.0.10 --cluster-domain=cluster.local --enable-debugging-handlers=true --eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%,imagefs.available<10%,imagefs.inodesFree<5% --kubeconfig=/var/lib/kubelet/kubeconfig --pod-manifest-path=/etc/kubernetes/manifests --register-schedulable=true --container-runtime=docker --docker=unix:///var/run/docker.sock --tls-cert-file=/srv/kubernetes/server.crt --tls-private-key-file=/srv/kubernetes/server.key --client-ca-file=/srv/kubernetes/ca.pem --node-labels=kubernetes.io/role=master,node-role.kubernetes.io/master="
```

Reload and check the status:

```
systemctl daemon-reload
systemctl start kubelet.service
systemctl enable kubelet.service
systemctl status -l kubelet.service

root@k8s01:/srv/kubernetes# kubectl get nodes --show-labels
NAME      STATUS    AGE       VERSION   LABELS
k8s01     Ready     10m       v1.6.7    beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/hostname=k8s01
k8s02     Ready     9m        v1.6.7    beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/hostname=k8s02
k8s03     Ready     8m        v1.6.7    beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/hostname=k8s03
```

## Option 2: Running as K8S Pod

TODO

# Kube-controller-manager

First make sure the Kubeconfig file for the service is present (it was generated in Step2):

```
# cat /var/lib/kube-controller-manager/kubeconfig 
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0t....
    server: https://k8s-api.virtual.local
  name: k8s.virtual.local
contexts:
- context:
    cluster: k8s.virtual.local
    user: kube-controller-manager
  name: k8s.virtual.local
current-context: k8s.virtual.local
kind: Config
preferences: {}
users:
- name: kube-controller-manager
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0t....
    token: ZQfdQlyKTKYCwfuyNW9FVunZPpMXdLTR
```

## Option 1: Running as K8S Pod

The [kube-controller-manager.yml]({{ site.baseurl }}/download/kube-controller-manager.yml) YAML Manifest available below and for download.

```
# /etc/kubernetes/manifests/kube-controller-manager.manifest
---
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    k8s-app: kube-controller-manager
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - command:
    - /bin/sh
    - -c
    - /usr/local/bin/kube-controller-manager --allocate-node-cidrs=true --attach-detach-reconcile-sync-period=1m0s
      --cluster-cidr=100.64.0.0/16 --cluster-name=k8s.virtual.local --service-cluster-ip-range=100.65.0.0/24
      --leader-elect=true --root-ca-file=/srv/kubernetes/ca.pem --configure-cloud-routes=false
      --service-account-private-key-file=/srv/kubernetes/apiserver-key.pem --use-service-account-credentials=true
      --v=2 --kubeconfig=/var/lib/kube-controller-manager/kubeconfig --cluster-signing-cert-file=/srv/kubernetes/ca.pem
      --cluster-signing-key-file=/srv/kubernetes/ca-key.pem 1>>/var/log/kube-controller-manager.log
      2>&1
    image: gcr.io/google_containers/kube-controller-manager:v1.6.7
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10252
      initialDelaySeconds: 15
      timeoutSeconds: 15
    name: kube-controller-manager
    resources:
      requests:
        cpu: 100m
    volumeMounts:
    - mountPath: /etc/ssl
      name: etcssl
      readOnly: true
    - mountPath: /srv/kubernetes
      name: srvkube
      readOnly: true
    - mountPath: /var/log/kube-controller-manager.log
      name: logfile
    - mountPath: /var/lib/kube-controller-manager
      name: varlibkcm
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/ssl
    name: etcssl
  - hostPath:
      path: /srv/kubernetes
    name: srvkube
  - hostPath:
      path: /var/log/kube-controller-manager.log
    name: logfile
  - hostPath:
      path: /var/lib/kube-controller-manager
    name: varlibkcm
```

## Option 2: Running as Systemd Service

Create a unit file:

```
root@k8s01:/srv/kubernetes# cat /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager Server
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service

[Service]
EnvironmentFile=/etc/sysconfig/kube-controller-manager
ExecStart=/usr/local/bin/kube-controller-manager "$DAEMON_ARGS"
Restart=always
RestartSec=2s
StartLimitInterval=0
KillMode=process

[Install]
WantedBy=multi-user.target
```

and the configuration file the above unit will load:

```
# /etc/sysconfig/kube-controller-manager 
DAEMON_ARGS="--v=2 --allocate-node-cidrs=true --attach-detach-reconcile-sync-period=1m0s --cluster-cidr=100.64.0.0/16 --cluster-name=k8s.virtual.local --leader-elect=true --root-ca-file=/srv/kubernetes/ca.pem --service-account-private-key-file=/srv/kubernetes/apiserver-key.pem --use-service-account-credentials=true --kubeconfig=/var/lib/kube-controller-manager/kubeconfig --cluster-signing-cert-file=/srv/kubernetes/ca.pem --cluster-signing-key-file=/srv/kubernetes/ca-key.pem --service-cluster-ip-range=100.65.0.0/24 --configure-cloud-routes=false"
```

Reload and check the status:

```
systemctl daemon-reload
systemctl start kube-controller-manager.service
systemctl enable kube-controller-manager.service
systemctl status -l kube-controller-manager.service
```

# Kube-proxy

I'm running this one as K8S Pod on each node. First make sure the Kubeconfig file for the service is in place (it was generated in Step2):

```
# /var/lib/kube-proxy/kubeconfig
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJ....
    server: https://k8s-api.virtual.local
  name: k8s.virtual.local
contexts:
- context:
    cluster: k8s.virtual.local
    user: kube-proxy
  name: k8s.virtual.local
current-context: k8s.virtual.local
kind: Config
preferences: {}
users:
- name: kube-proxy
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJ....
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJ....
    token: mwMnYxBXeB3sGPvNTjS0Yjwby4LU0JLl
```

Manual test run:

```
kube-proxy --kubeconfig=/var/lib/kube-proxy/kubeconfig --conntrack-max-per-core=131072 --cluster-cidr=100.64.0.0/16 --master=https://127.0.0.1 --v=2 2>&1 | /usr/bin/tee /var/log/kube-proxy.log
```

The [kube-proxy.yml]({{ site.baseurl }}/download/kube-proxy.yml) YAML Manifest available below and for download.

```
# /etc/kubernetes/manifests/kube-proxy.manifest
---
apiVersion: v1
kind: Pod
metadata:
  annotations:
    scheduler.alpha.kubernetes.io/critical-pod: ""
  creationTimestamp: null
  labels:
    k8s-app: kube-proxy
    tier: node
  name: kube-proxy
  namespace: kube-system
spec:
  containers:
  - command:
    - /bin/sh
    - -c
    - echo -998 > /proc/$$$/oom_score_adj && kube-proxy --kubeconfig=/var/lib/kube-proxy/kubeconfig
      --conntrack-max-per-core=131072 --resource-container="" --cluster-cidr=100.64.0.0/16
      --master=https://127.0.0.1 --proxy-mode=iptables --v=2 2>&1 | /usr/bin/tee /var/log/kube-proxy.log
    image: gcr.io/google_containers/kube-proxy:v1.6.7
    imagePullPolicy: IfNotPresent
    name: kube-proxy
    resources:
      requests:
        cpu: 100m
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /var/log
      name: varlog
    - mountPath: /var/lib/kube-proxy
      name: kubeconfig
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ssl-certs-hosts
      readOnly: true
  hostNetwork: true
  volumes:
  - hostPath:
      path: /var/log
    name: varlog
  - hostPath:
      path: /var/lib/kube-proxy
    name: kubeconfig
  - hostPath:
      path: /usr/share/ca-certificates
    name: ssl-certs-hosts
```

The Pods status:

```
root@k8s01:~# kubectl get pods -o wide -n kube-system
NAME               READY     STATUS    RESTARTS   AGE       IP              NODE
kube-proxy-k8s01   1/1       Running   0          4m        192.168.0.147   k8s01
kube-proxy-k8s02   1/1       Running   0          33s       192.168.0.148   k8s02
kube-proxy-k8s03   1/1       Running   0          29s       192.168.0.148   k8s03
```

# Kube-scheduler

I'm running this one as K8S Pod on each node. First make sure the Kubeconfig file for the service is in place (it was generated in Step2):

```
# /var/lib/kube-scheduler/kubeconfig
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0t....
    server: https://k8s-api.virtual.local
  name: k8s.virtual.local
contexts:
- context:
    cluster: k8s.virtual.local
    user: kube-scheduler
  name: k8s.virtual.local
current-context: k8s.virtual.local
kind: Config
preferences: {}
users:
- name: kube-scheduler
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0t....
    token: NedDdabIJhzfby96e7wWCwlInPmUvnKz
```

The [kube-scheduler.yml]({{ site.baseurl }}/download/kube-scheduler.yml) YAML Manifest available below and for download.

```
# /etc/kubernetes/manifests/kube-scheduler.manifest
---
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  labels:
    k8s-app: kube-scheduler
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - /bin/sh
    - -c
    - /usr/local/bin/kube-scheduler --leader-elect=true --v=2 --kubeconfig=/var/lib/kube-scheduler/kubeconfig
      1>>/var/log/kube-scheduler.log 2>&1
    image: gcr.io/google_containers/kube-scheduler:v1.6.7
    livenessProbe:
      httpGet:
        host: 127.0.0.1
        path: /healthz
        port: 10251
      initialDelaySeconds: 15
      timeoutSeconds: 15
    name: kube-scheduler
    resources:
      requests:
        cpu: 100m
    volumeMounts:
    - mountPath: /var/lib/kube-scheduler
      name: varlibkubescheduler
      readOnly: true
    - mountPath: /var/log
      name: logfile
  hostNetwork: true
  volumes:
  - hostPath:
      path: /var/lib/kube-scheduler
    name: varlibkubescheduler
  - hostPath:
      path: /var/log
    name: logfile
```

{% include series.html %}