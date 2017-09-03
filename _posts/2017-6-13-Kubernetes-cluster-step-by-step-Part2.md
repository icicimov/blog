---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Binaries, Certificates, Kubeconfig and Tokens'
categories: 
  - Kubernetes
tags: ['kubernetes', 'openssl']
date: 2017-6-13
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

# Kubernetes Setup

In this step we install the K8S binaries and prepare the needed certificates and API authentication for various Kubernetes components.

## Installation

First we install the Kubernetes binaries on each of the nodes:

```
# cd /opt
# wget https://github.com/kubernetes/kubernetes/releases/download/v1.6.7/kubernetes.tar.gz
# tar -xzf kubernetes.tar.gz
# ./kubernetes/cluster/get-kube-binaries.sh
...
Extracting /opt/kubernetes/client/kubernetes-client-linux-amd64.tar.gz into /opt/kubernetes/platforms/linux/amd64
Add '/opt/kubernetes/client/bin' to your PATH to use newly-installed binaries.

# cd /opt/kubernetes/server/
# tar -xzvf kubernetes-server-linux-amd64.tar.gz
# export PATH=/opt/kubernetes/client/bin:/opt/kubernetes/server/kubernetes/server/bin:$PATH
# cp client/bin/kubectl /usr/local/bin/
# cp server/kubernetes/server/bin/{hyperkube,kubeadm,kube-apiserver,kubelet,kube-proxy} /usr/local/bin/
```

Then create the Directory structure for the services that will run on the nodes outside of the Kubernetes cluster:

```
# mkdir -p /var/lib/{kube-controller-manager,kubelet,kube-proxy,kube-scheduler}
# mkdir -p /etc/{kubernetes,sysconfig}
# mkdir -p /etc/kubernetes/manifests
```

## K8S certificates

### K8S CA Setup

On each node create the directory for the K8S certs:

```
mkdir -p /srv/kubernetes
```

And go though the following procedure on `k8s01` only to create the certs. When finished copy the content of the certificate directory below to `k8s02` and `k8s03`.

Start with creating the CA cert key-pair:

```
cd /srv/kubernetes
openssl genrsa -out ca-key.pem 2048
openssl req -x509 -new -nodes -key ca-key.pem -days 10000 -out ca.pem -subj "/CN=kube-ca"
```

This is the CA we will use to sign the rest of the cluster certificates.

### K8S Master Certificate

Create the following `openssl.cnf` file:

```
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = kubernetes
DNS.2 = kubernetes.default
DNS.3 = kubernetes.default.svc
DNS.4 = kubernetes.default.svc.cluster.local
DNS.5 = k8s-api.virtual.local
DNS.6 = k8s01.virtual.local
DNS.7 = k8s02.virtual.local
DNS.8 = k8s03.virtual.local
DNS.9 = k8s01
DNS.10 = k8s02
DNS.11 = k8s03
DNS.12 = localhost
IP.1 = 100.65.0.1
IP.2 = 192.168.0.147
IP.3 = 192.168.0.148
IP.4 = 192.168.0.149
IP.5 = 192.168.0.150
IP.6 = 127.0.0.1
```

We will use this file to create the certificate for `kube-apiserver` service:

```
openssl genrsa -out apiserver-key.pem 2048
openssl req -new -key apiserver-key.pem -out apiserver.csr -subj "/CN=kube-apiserver" -config openssl.cnf
openssl x509 -req -in apiserver.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
  -out apiserver.pem -days 7200 -extensions v3_req -extfile openssl.cnf
cp apiserver.pem server.crt
cp apiserver-key.pem server.key
```

### K8S Services and Admin User Key-pair

Generate the Cluster Administrator Key-pair (for Kubeconfig):

```
openssl genrsa -out admin-key.pem 2048
openssl req -new -key admin-key.pem -out admin.csr -subj "/CN=admin"
openssl x509 -req -in admin.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out admin.pem -days 7200
```

Actually create in one go the certs for the `admin` user and rest of the Kubernetes services:

```
for user in admin kube-proxy kubelet kube-controller-manager kube-scheduler
do
    openssl genrsa -out ${user}-key.pem 2048
    openssl req -new -key ${user}-key.pem -out ${user}.csr -subj "/CN=${user}"
    openssl x509 -req -in ${user}.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ${user}.pem -days 7200
done
```

### Generate the Kubernetes Worker Key-pairs (Optional)

In case we later create additional separate Workers we want them to have different certificate so we create `worker-openssl.cnf` for each of them that might look something like this:

```
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = WORKER_NAME.virtual.local
IP.1 = WORKER_IP
```

and use them to generate the worker certificates. Run the following set of commands once for every worker node in the planned cluster. Replace `WORKER_FQDN` and `WORKER_IP` in the following commands with the correct values for each node.

```
openssl genrsa -out ${WORKER_FQDN}-worker-key.pem 2048
WORKER_IP=${WORKER_IP} openssl req -new -key ${WORKER_FQDN}-worker-key.pem -out ${WORKER_FQDN}-worker.csr \
  -subj "/CN=${WORKER_FQDN}" -config worker-openssl.cnf
WORKER_IP=${WORKER_IP} openssl x509 -req -in ${WORKER_FQDN}-worker.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out ${WORKER_FQDN}-worker.pem -days 7200 -extensions v3_req -extfile worker-openssl.cnf
```

## Kubeconfig

This procedure will create `Kubeconfig` file for the `admin` and all of the K8S services used to get access to the API service.

We start with the `admin` user. Create a token:

```
dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null
uZ2SgbD6IOrANyLrx8VkMarTrycJa1lG
```

Then on each Master run the following command block as `root` user:

```
TOKEN="uZ2SgbD6IOrANyLrx8VkMarTrycJa1lG"
kubectl config set-cluster k8s.virtual.local --certificate-authority=/srv/kubernetes/ca.pem \
  --embed-certs=true --server=https://k8s-api.virtual.local
kubectl config set-credentials admin --client-certificate=/srv/kubernetes/admin.pem \
  --client-key=/srv/kubernetes/admin-key.pem --embed-certs=true --token=$TOKEN
kubectl config set-context k8s.virtual.local --cluster=k8s.virtual.local --user=admin
kubectl config use-context k8s.virtual.local
```

After this we have the config file:

```
root@k8s01:~# cat ~/.kube/config 
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t....
    server: https://k8s-api.virtual.local
  name: k8s.virtual.local
contexts:
- context:
    cluster: k8s.virtual.local
    user: admin
  name: k8s.virtual.local
current-context: k8s.virtual.local
kind: Config
preferences: {}
users:
- name: admin
  user:
    client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FUR....
    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJV....
    token: uZ2SgbD6IOrANyLrx8VkMarTrycJa1lG
```

The `k8s-api.virtual.local` is the DNS name of the K8S Master (API) service that we will make available and load-balanced via HAProxy in a procedure described later. 

The Kubeconfig for the rest of the services (on one Master only):

```bash
for user in kubelet kube-proxy kube-controller-manager kube-scheduler
do
TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
kubectl config set-cluster k8s.virtual.local --certificate-authority=/srv/kubernetes/ca.pem --embed-certs=true --server=https://k8s-api.virtual.local --kubeconfig=/var/lib/${user}/kubeconfig
kubectl config set-credentials ${user} --client-certificate=/srv/kubernetes/${user}.pem --client-key=/srv/kubernetes/${user}-key.pem --embed-certs=true --token=$TOKEN --kubeconfig=/var/lib/${user}/kubeconfig
kubectl config set-context k8s.virtual.local --cluster=k8s.virtual.local --user=${user} --kubeconfig=/var/lib/${user}/kubeconfig
#kubectl config use-context k8s.virtual.local --kubeconfig=/var/lib/${user}/kubeconfig
done
```

Now copy the files to the rest of the Masters.

## Tokens and Basic Authentication files

We Create the `known_tokens.csv` file on one of the masters. This can be done manually or by just including: 

```
echo "$TOKEN,$user,$user" >> /srv/kubernetes/known_tokens.csv
```

in the `for` loop of the above scriplet. I also create a `basic_auth.csv` file with the admin's user password as another option of authentication apart from tokens:

```
cat /srv/kubernetes/basic_auth.csv
SRFZr2HADjUD5z2Y7nFtxfdBhoiccDRy,admin,admin,system:masters
```
{% include series.html %}
