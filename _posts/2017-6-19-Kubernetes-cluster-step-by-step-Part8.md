---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Services and Load Balancing'
categories: 
  - Kubernetes
tags: ['kubernetes', 'træfik']
date: 2017-6-19
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

# Træfik

[Træfik](https://traefik.io/) (pronounced like traffic) is a modern HTTP reverse proxy and load balancer made to deploy microservices with ease. It supports several backends (Docker, Swarm mode, Kubernetes, Marathon, Consul, Etcd, Rancher, Amazon ECS, and a lot more) to manage its configuration automatically and dynamically.

![Træfik architecture](/blog/images/traefik-architecture.png "Træfik architecture")

We can install it as Deployment (no HA, one Pod) or DaemonSet (for HA). The [Manifest needed](https://github.com/containous/traefik/tree/master/examples/k8s) can be downloaded from the GitHub repository.

We want Træfik SSL enabled and possibly working with LetsEncrypt.

## Create Role and Binding for the ServiceAccount

```
# traefik-rbac.yml 
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: traefik-ingress-controller
rules:
  - apiGroups:
      - ""
    resources:
      - pods
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1beta1
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
- kind: ServiceAccount
  name: traefik-ingress-controller
  namespace: kube-system
```

Create the IngressController and the RoleBinding:

```
root@k8s01:~# kubectl create -f traefik-rbac.yml
clusterrole "traefik-ingress-controller" created
clusterrolebinding "traefik-ingress-controller" created
```

## Create a ConfigMap that wil hold the Træfik configuration

```
# traefik-config-map.yml 
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: kube-system
  name: traefik-conf
data:
  traefik.toml: |
    # traefik.toml
    logLevel = "DEBUG"
    defaultEntryPoints = ["http","https"]
    [entryPoints]
      [entryPoints.http]
      address = ":80"
      [entryPoints.http.redirect]
      entryPoint = "https"
      # Enable basic authentication
      #[entryPoints.https.auth.basic]
      #users = ["igorc:$apr1$k2qslCn6$0OgA8vhnyC8nJ99YfJMOM/"]
      [entryPoints.https]
      address = ":443"
      [entryPoints.https.tls]
      # Enable this only if using static wildcard cert
      # stored in a k8s Secret instead of LetsEncrypt
      #[[entryPoints.https.tls.certificates]]
      #CertFile = "/ssl/tls.crt"
      #KeyFile = "/ssl/tls.key"
    [kubernetes]
    [web]
    address = ":8080"
    # Enable basic authentication
    #  [web.auth.basic]
    #    users = ["igorc:$apr1$k2qslCn6$0OgA8vhnyC8nJ99YfJMOM/"]
    [acme]
    email = "igorc@encompasscorporation.com"
    #storage = "traefik/acme/account"   # for KV store
    storage = "/acme/acme.json"
    entryPoint = "https"
    onDemand = true
    onHostRule = true
    # For Staging, comment out to go to Prod
    caServer = "https://acme-staging.api.letsencrypt.org/directory"
    [[acme.domains]]
    main = "virtual.local"
    sans = ["nodejs-app.virtual.local", "encompass.virtual.local"]
    # For Consul KV store
    #[consul]
    #endpoint = "traefik-consul:8500"
    #watch = true
    #prefix = "traefik"
    # For Docker containers
    #[docker]
    #endpoint = "unix:///var/run/docker.sock"
    #domain = "docker.localhost"
    #watch = true
```

Apply the above Manifest:

```
root@k8s01:~# kubectl create -f traefik-config-map.yml
configmap "traefik-conf" created
```

## Create the ServiceAccount

```
# traefik-service-account.yml 
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
```

Apply the above Manifest:

```
root@k8s01:~# kubectl create -f traefik-service-account.yml
serviceaccount "traefik-ingress-controller" created
```

## Create the Service

Apply the following Manifest:

```
# traefik-service.yml
---
kind: Service
apiVersion: v1
metadata:
  name: traefik-ingress-service
  namespace: kube-system
spec:
  selector:
    k8s-app: traefik-ingress-lb
  ports:
    - protocol: TCP
      port: 80
      name: http
    - protocol: TCP
      port: 8080
      name: admin
    - protocol: TCP
      port: 443
      name: https
  type: NodePort
```

## Create the Deployment

Apply the following Manifest:

```
# traefik-deployment.yml
---
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  name: traefik-ingress-controller
  namespace: kube-system
  labels:
    k8s-app: traefik-ingress-lb
spec:
  replicas: 1
  revisionHistoryLimit: 1
  selector:
    matchLabels:
      k8s-app: traefik-ingress-lb
  strategy:
    # better for stateless services, no outage
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        k8s-app: traefik-ingress-lb
        name: traefik-ingress-lb
    spec:
      serviceAccountName: traefik-ingress-controller
      terminationGracePeriodSeconds: 60
      volumes:
      - name: config
        configMap:
          name: traefik-conf
      # Enable this only if using static wildcard cert
      # stored in a k8s Secret instead of LetsEncrypt
      #- name: ssl
      #  secret:
      #    secretName: traefik-cert
      containers:
      - image: traefik
        name: traefik-ingress-lb
        imagePullPolicy: Always
        resources:
          limits:
            cpu: 200m
            memory: 30Mi
          requests:
            cpu: 100m
            memory: 20Mi
        volumeMounts:
        - mountPath: "/config"
          name: "config"
        # Enable this only if using static wildcard cert
        # stored in a k8s Secret instead of LetsEncrypt
        #- mountPath: "/ssl"
        #  name: "ssl"
        ports:
        - containerPort: 80
        - containerPort: 443
        - containerPort: 8080
        args:
        - --web
        - --kubernetes
        - --configfile=/config/traefik.toml
```

In case of using the LE Staging, import the [LetsEncrypt test signing cert](https://letsencrypt.org/certs/fakelerootx1.pem) in the browser so it can be trusted (get a green padlock). 

## Static wildcard cert instead of LetsEncrypt 

We need to forward port 443 on the router to the VM's in order for LetsEncrypt to connect and verify the domain when issuing certificates. When this is not an option creating a self-signed cert is better approach. 

Create the cert and the key:

```
root@k8s01:~# openssl req -newkey rsa:2048 -nodes -keyout tls.key -x509 -days 365 -out tls.crt -subj '/CN=*.virtual.local'
Generating a 2048 bit RSA private key
.....................+++
.....................................................+++
writing new private key to 'tls.key'
-----
```

Create the k8s `Secret` that will hold the cert:

```
root@k8s01:~# kubectl create secret generic traefik-cert --from-file=tls.crt --from-file=tls.key --namespace=kube-system
secret "traefik-cert" created

root@k8s01:~# kubectl get secrets/traefik-cert -o yaml --namespace=kube-system
apiVersion: v1
data:
  tls.crt: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JS....
  tls.key: LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCk1JS....
kind: Secret
metadata:
  creationTimestamp: 2017-08-11T05:38:27Z
  name: traefik-cert
  namespace: default
  resourceVersion: "3419930"
  selfLink: /api/v1/namespaces/default/secrets/traefik-cert
  uid: 4ca5f148-7e57-11e7-bdf8-0a7d22009a99
type: Opaque
```

Uncomment the TLS section in `traefik-config-map.yml` file: 

```
# traefik-config-map.yml 
---
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: kube-system
  name: traefik-conf
data:
  traefik.toml: |
    # traefik.toml
...
      [entryPoints.https.tls]
      [[entryPoints.https.tls.certificates]]
      CertFile = "/ssl/tls.crt"
      KeyFile = "/ssl/tls.key"
...
```

and the SSL mount point in the `traefik-deployment.yml` file:

```
# cat traefik-deployment.yml
[...]
---
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
...
    spec:
      serviceAccountName: traefik-ingress-controller
      terminationGracePeriodSeconds: 60
      volumes:
      - name: config
        configMap:
          name: traefik-conf
      - name: ssl
        secret:
          secretName: traefik-cert
...
```

and re-apply those two files to update the configuration.

## Setting HAProxy for Træfik

The following is the relevant config in `/etc/haproxy/haproxy.cfg` file:

```
frontend traefik
        bind 192.168.0.150:8081
        bind 127.0.0.1:8081
        mode tcp
        option tcplog
        default_backend traefik

frontend k8s-api
        bind 192.168.0.150:443
        bind 127.0.0.1:443
        mode tcp
        option tcplog
        tcp-request inspect-delay 5s
        tcp-request content accept if { req.ssl_hello_type 1 }
        use_backend traefik-lb if { req.ssl_sni -m found } !{ req.ssl_sni -i k8s-api.virtual.local }
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

backend traefik-lb
        mode tcp
        option tcplog
        option tcp-check
        balance roundrobin
        default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
        server traefik-1 192.168.0.147:31287 check
        server traefik-2 192.168.0.148:31287 check
        server traefik-3 192.168.0.149:31287 check

backend traefik
        mode tcp
        option tcplog
        option tcp-check
        balance roundrobin
        default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
        server traefik-1 192.168.0.147:31236 track traefik-lb/traefik-1
        server traefik-2 192.168.0.148:31236 track traefik-lb/traefik-2
        server traefik-3 192.168.0.149:31236 track traefik-lb/traefik-3
```

Now we can access Træfik console at `http://traefik.virtual.local:8081/dashboard/`, after updating our `/etc/hosts` file:

```
# K8S VMs cluster in Proxmox
192.168.0.150   k8s-api.virtual.local nodejs-app.virtual.local traefik.virtual.local
```

and any Service referenced by Ingress at `https://<service-name>.virtual.local`.

## Create Ingress for our nodejs-app service

The node-js app is created by the following [nodejs-app.yml]({{ site.baseurl }}/download/nodejs-app.yml)) Manifest available for download. 

Then apply the following Manifest to create the Ingress:

```
# traefik-ingress-all.yml
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
 name: traefik-ingress
 namespace: default
spec:
  rules:
  - host: nodejs-app.virtual.local
    http:
      paths:
      - path: /
        backend:
          serviceName: nodejs-app-svc
          servicePort: 80
  tls:
  - hosts:
    - nodejs-app.virtual.local 
    secretName: traefik-cert
```

And test the setup:

```
igorc@igor-laptop:~$ for i in `seq 1 4`; do curl -ksSNL -H "Host: nodejs-app.virtual.local" https://nodejs-app.virtual.local/; done
I am: nodejs-app-deployment-4489171-11s4j
I am: nodejs-app-deployment-4489171-zf48m
I am: nodejs-app-deployment-4489171-11s4j
I am: nodejs-app-deployment-4489171-zf48m
```

We can see we are hitting both Pods in the service in round-robin fashion which means the load-balancing is working. The dashboard screen shot showing the application status of load balancer: 

[![Træfik dashboard](/blog/images/traefik-dashboard.png)](/blog/images/traefik-dashboard.png "Træfik dashboard")

and the HAProxy dashboard showing the Traefik instance running on one of the K8S nodes:

[![Træfik in HAProxy dashboard](/blog/images/k8s-haproxy-dashboard-traefik.png)](/blog/images/k8s-haproxy-dashboard-traefik.png "Træfik in HAProxy dashboard")

{% include series.html %}
