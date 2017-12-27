---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes cluster step-by-step: Kubernetes Add-ons'
categories: 
  - Kubernetes
tags: ['kubernetes']
date: 2017-6-18
excerpt: "The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes"
series: "Kubernetes cluster step-by-step"
---
{% include toc %}
The purpose of this exercise is to create local `Kubernetes` cluster for testing deployments. It will be deployed on 3 x VMs (Debian Jessie 8.8) nodes which will be Master and Worker nodes in same time. The nodes names will be k8s01 (192.168.0.147), k8s02 (192.168.0.148) and k8s03 (192.168.0.149). All work is done as `root` user unless otherwise specified. Each node has the IPs, short and FQDN of all the nodes set in its local hosts file.

Create permissive `ServiceAccount` to use for deployments in case of RBAC issues:

```
root@k8s01:~# kubectl create clusterrolebinding permissive-binding \
   --clusterrole=cluster-admin \
   --user=admin \
   --user=kubelet \
   --group=system:serviceaccounts

clusterrolebinding "permissive-binding" created
```

# Dashboard

The [kubernetes-dashboard.yml]({{ site.baseurl }}/download/kubernetes-dashboard.yml) YAML file available below and for download.

```
# kubernetes-dashboard.yml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: kubernetes-dashboard
    k8s-addon: kubernetes-dashboard.addons.k8s.io
    k8s-app: kubernetes-dashboard
  name: kubernetes-dashboard
  namespace: kube-system
---  
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-addon: kubernetes-dashboard.addons.k8s.io
    k8s-app: kubernetes-dashboard
    version: v1.6.1
    kubernetes.io/cluster-service: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kubernetes-dashboard
  template:
    metadata:
      labels:
        k8s-addon: kubernetes-dashboard.addons.k8s.io
        k8s-app: kubernetes-dashboard
        version: v1.6.1
        kubernetes.io/cluster-service: "true"
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
    spec:
      containers:
      - name: kubernetes-dashboard
        image: gcr.io/google_containers/kubernetes-dashboard-amd64:v1.6.1
        resources:
          # keep request = limit to keep this container in guaranteed class
          limits:
            cpu: 100m
            memory: 50Mi
          requests:
            cpu: 100m
            memory: 50Mi
        ports:
        - containerPort: 9090
        livenessProbe:
          httpGet:
            path: /
            port: 9090
          initialDelaySeconds: 30
          timeoutSeconds: 30
      serviceAccountName: kubernetes-dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard
  namespace: kube-system
  labels:
    k8s-addon: kubernetes-dashboard.addons.k8s.io
    k8s-app: kubernetes-dashboard
    kubernetes.io/cluster-service: "true"
spec:
  selector:
    k8s-app: kubernetes-dashboard
  ports:
  - port: 80
    targetPort: 9090
```

After applying the above Manifest the Dashboard can be accessed at `https://192.168.0.150/ui/`.

# Kube-DNS

The kube-dns addon will make possible for the service DNS names to resolve internally in the cluster. The [kube-dns.yml]({{ site.baseurl }}/download/kube-dns.yml) YAML file available below and for download.

```
# kube-dns.yml 
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
---
apiVersion: v1
kind: Service
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    kubernetes.io/name: "KubeDNS"
spec:
  selector:
    k8s-app: kube-dns
  clusterIP: 100.64.0.10
  ports:
  - name: dns
    port: 53
    protocol: UDP
  - name: dns-tcp
    port: 53
    protocol: TCP
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    k8s-app: kube-dns
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: Reconcile
spec:
  # replicas: not specified here:
  # 1. In order to make Addon Manager do not reconcile this replicas parameter.
  # 2. Default is 1.
  # 3. Will be tuned in real time if DNS horizontal auto-scaling is turned on.
  strategy:
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  selector:
    matchLabels:
      k8s-app: kube-dns
  template:
    metadata:
      labels:
        k8s-app: kube-dns
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ''
    spec:
      tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      volumes:
      - name: kube-dns-config
        configMap:
          name: kube-dns
          optional: true
      containers:
      - name: kubedns
        image: gcr.io/google_containers/k8s-dns-kube-dns-amd64:1.14.4
        resources:
          # TODO: Set memory limits when we've profiled the container for large
          # clusters, then set request = limit to keep this container in
          # guaranteed class. Currently, this container falls into the
          # "burstable" category so the kubelet doesn't backoff from restarting it.
          limits:
            memory: 170Mi
          requests:
            cpu: 100m
            memory: 70Mi
        livenessProbe:
          httpGet:
            path: /healthcheck/kubedns
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8081
            scheme: HTTP
          # we poll on pod startup for the Kubernetes master service and
          # only setup the /readiness HTTP server once that's available.
          initialDelaySeconds: 3
          timeoutSeconds: 5
        args:
        - --domain=cluster.local.
        - --dns-port=10053
        - --config-dir=/kube-dns-config
        - --v=2
        env:
        - name: PROMETHEUS_PORT
          value: "10055"
        ports:
        - containerPort: 10053
          name: dns-local
          protocol: UDP
        - containerPort: 10053
          name: dns-tcp-local
          protocol: TCP
        - containerPort: 10055
          name: metrics
          protocol: TCP
        volumeMounts:
        - name: kube-dns-config
          mountPath: /kube-dns-config
      - name: dnsmasq
        image: gcr.io/google_containers/k8s-dns-dnsmasq-nanny-amd64:1.14.4
        livenessProbe:
          httpGet:
            path: /healthcheck/dnsmasq
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - -v=2
        - -logtostderr
        - -configDir=/etc/k8s/dns/dnsmasq-nanny
        - -restartDnsmasq=true
        - --
        - -k
        - --cache-size=1000
        - --log-facility=-
        - --server=/cluster.local/127.0.0.1#10053
        - --server=/in-addr.arpa/127.0.0.1#10053
        - --server=/ip6.arpa/127.0.0.1#10053
        ports:
        - containerPort: 53
          name: dns
          protocol: UDP
        - containerPort: 53
          name: dns-tcp
          protocol: TCP
        # see: https://github.com/kubernetes/kubernetes/issues/29055 for details
        resources:
          requests:
            cpu: 150m
            memory: 20Mi
        volumeMounts:
        - name: kube-dns-config
          mountPath: /etc/k8s/dns/dnsmasq-nanny
      - name: sidecar
        image: gcr.io/google_containers/k8s-dns-sidecar-amd64:1.14.4
        livenessProbe:
          httpGet:
            path: /metrics
            port: 10054
            scheme: HTTP
          initialDelaySeconds: 60
          timeoutSeconds: 5
          successThreshold: 1
          failureThreshold: 5
        args:
        - --v=2
        - --logtostderr
        - --probe=kubedns,127.0.0.1:10053,kubernetes.default.svc.cluster.local,5,A
        - --probe=dnsmasq,127.0.0.1:53,kubernetes.default.svc.cluster.local,5,A
        ports:
        - containerPort: 10054
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: 20Mi
            cpu: 10m
      dnsPolicy: Default  # Don't use cluster DNS.
      serviceAccountName: kube-dns
```

# Kube-dns-autoscaller

The `kube-dns-autoscaller` addon will provide horizontal autoscaling feature for DNS service in the cluster. The [kube-dns-autoscaller.yml]({{ site.baseurl }}/download/kube-dns-autoscaller.yml) YAML file available below and for download.

```
# kube-dns-autoscaller.yml
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  labels:
    k8s-addon: kube-dns.addons.k8s.io
    k8s-app: kube-dns-autoscaler
    kubernetes.io/cluster-service: "true"
  name: kube-dns-autoscaler
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kube-dns-autoscaler
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ""
        scheduler.alpha.kubernetes.io/tolerations: '[{"key":"CriticalAddonsOnly", "operator":"Exists"}]'
      creationTimestamp: null
      labels:
        k8s-app: kube-dns-autoscaler
    spec:
      containers:
      - command:
        - /cluster-proportional-autoscaler
        - --namespace=kube-system
        - --configmap=kube-dns-autoscaler
        - --target=Deployment/kube-dns
        - --default-params={"linear":{"coresPerReplica":256,"nodesPerReplica":16,"preventSinglePointFailure":true}}
        - --logtostderr=true
        - --v=2
        image: gcr.io/google_containers/cluster-proportional-autoscaler-amd64:1.1.1
        imagePullPolicy: IfNotPresent
        name: autoscaler
        resources:
          requests:
            cpu: 20m
            memory: 10Mi
        terminationMessagePath: /dev/termination-log
        terminationMessagePolicy: File
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      schedulerName: default-scheduler
      securityContext: {}
      serviceAccount: kube-dns-autoscaler
      serviceAccountName: kube-dns-autoscaler
      terminationGracePeriodSeconds: 30
```

The `ServiceRole` and `RoleBindings` for the DNS-Autoscaler (download from [kube-dns-autoscaler-service-account-rbac.yml]({{ site.baseurl }}/download/kube-dns-autoscaler-service-account-rbac.yml)):

```
# kube-dns-autoscaler-service-account-rbac.yml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-dns-autoscaler
  namespace: kube-system
  labels:
    k8s-addon: kube-dns.addons.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  labels:
    k8s-addon: kube-dns.addons.k8s.io
  name: kube-dns-autoscaler
rules:
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - list
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - get
  - create
  - update
- apiGroups:
  - "extensions"
  resources:
  - deployments/scale
  verbs:
  - get
  - update
---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  labels:
    k8s-addon: kube-dns.addons.k8s.io
  name: kube-dns-autoscaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-dns-autoscaler
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:serviceaccount:kube-system:kube-dns-autoscaler
```

# Cluster DNS functionality check

Confirm the DNS in the cluster is working:

```
# busybox.yml 
apiVersion: v1
kind: Pod
metadata:
  name: busybox
  namespace: default
spec:
  containers:
  - image: busybox
    command:
      - sleep
      - "3600"
    imagePullPolicy: IfNotPresent
    name: busybox
  restartPolicy: Always
```

Create the `busybox` Pod:

```
kubectl create -f busybox.yml
```

Login and run a DNS check:

```
root@k8s01:~# kubectl exec -i --tty busybox -- nslookup nodejs-app-svc.default.svc.cluster.local
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local

Name:      nodejs-app-svc.default.svc.cluster.local
Address 1: 100.64.106.219 nodejs-app-svc.default.svc.cluster.local

root@k8s01:~# kubectl exec -i --tty busybox -- nslookup nodejs-app-svc
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local

Name:      nodejs-app-svc
Address 1: 100.64.106.219 nodejs-app-svc.default.svc.cluster.local
```

We an see the DNS resolution working for both long and short (`default` namespace) service name.

{% include series.html %}
