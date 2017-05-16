---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes Applications and Services'
categories: 
  - Virtualization
tags: [kubernetes, docker]
date: 2017-4-13
series: "Kubernetes Cluster in AWS"
---
{% include toc %}
In my previous post [Kubernetes Cluster in AWS with Kops]({{ site.baseurl }}{% post_url 2017-4-12-Kubernetes-Cluster-in-AWS-with-Kops %}) I deployed a Kubernetes cluster with fully private topology (subnets and DNS vise) in existing AWS VPC using Kops. Now it's time to start deploying to it and exploring its functionality. 

# Applications and Services

## Deployments

The best and recommended option for deploying applications/services in Kubernetes are [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/). They provide declarative updates for Pods and Replica Sets (the next-generation Replication Controller). We only need to describe the desired state in a Deployment object, and the Deployment controller will change the actual state to the desired state at a controlled rate for you. We can define Deployments to create new resources, or replace existing ones by new ones.

But before we start with it we need to understand Services. A Kubernetes Service is an abstraction which defines a logical set of Pods and a policy by which to access them - sometimes called a micro-service. The set of Pods targeted by a Service is (usually) determined by a Label Selector.

So, the Deployment will describe how and where our Containers/Pods containing our application will get deployed and Service will describe how they are going to be accessed as one compact unit via single access point and in transparent fashion to the client.

Every single resource we build in Kubernetes is described via YAML configuration file following strict specification appropriate for the unit we are creating. The following `nodejs-app.yml` YAML file describes our `nodejs-app` application and the way we want it deployed by Kubernetes in our cluster:

```
---
apiVersion: v1
kind: Service
metadata:
  name: nodejs-app
  namespace: default
  labels:
    name: nodejs-app
spec:
  type: ClusterIP    # default
  #ClusterIP: None   # for Headless Services
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    # This needs to match the selector in the RC/Deployment
    app: nodejs-app
 
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: nodejs-app
  namespace: default
  labels:
    app: nodejs-app
spec:
  revisionHistoryLimit: 3
  replicas: 2    # or we can even skip this, just want to test the HAP below, otherwise start with 3 lets say
  selector:
    matchLabels:
      app: nodejs-app
  strategy:
    #type: Recreate       # destroy all before creating new pods (default)
    type: RollingUpdate   # better for stateless services, no outage
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: nodejs-app
        tier: frontend
    spec:
      containers:
      - name: nodejs-app
        image: igoratencompass/nodejs-app:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
          name: nodejs-app
        resources:
          limits:
            cpu: "100m"
            memory: 256Mi
          requests:
            cpu: "10m"
            memory: 64Mi
        readinessProbe:
          successThreshold: 1
          failureThreshold: 2
          periodSeconds: 5
          initialDelaySeconds: 5   # Important so that the container doesn't get traffic too soon
          httpGet:
            path: /
            port: 8080
            scheme: HTTP
        livenessProbe:
          successThreshold: 1
          failureThreshold: 2
          periodSeconds: 5
          initialDelaySeconds: 5
          timeoutSeconds: 1
          httpGet:
            path: /health
            port: 8080
            scheme: HTTP
        lifecycle:                # Needed for no-downtime deployments with IngressController
          preStop:
            exec:
              command: ["sleep, "5"]
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      securityContext: {}
      terminationGracePeriodSeconds: 30
```

The Deployment part describes the resources each of our Pods needs in terms of CPU (1000m = 1xCPU time) and Memory, the way we want them deployed and upgraded (rolling update), the health and readiness health checks, how many revisions to keep in history in case we want to quickly roll back. The Service part describes how do we want our application accessed in this case via DNS name of `nodejs-app` (its k8s job to make this resolvable for all Pods in the cluster) and on which port(s). If we create a Service for that Deployment before creating the said Deployment, Kubernetes will spread our pods evenly across the available nodes.

In case we need to download images from private repository we can use Secrets to store the sensitive information:

```
$ kubectl create secret docker-registry encompass-gitlab-registry --docker-server="git.encompasshost.com:5001" \
  --docker-username="<user>" --docker-password="<password>" --docker-email=<email>
```

and then use this Secret in our deployment via `imagePullSecrets` parameter to supply the user info in the image download phase:

```
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: nodejs-app
  namespace: default
[...]
  template:
    metadata:
      labels:
        app: nodejs-app
        tier: frontend
    spec:
      containers:
      - name: nodejs-app
        image: git.encompasshost.com:5001/encompass/nodejs-app/nodejs-app:latest
        imagePullPolicy: IfNotPresent
[...]
      terminationGracePeriodSeconds: 30
      imagePullSecrets:
        - name: encompass-gitlab-registry
```

### Initial deployment

The initial deployment of our test app looks like this:

```
igorc@igor-laptop:~$ kubectl rollout status deployments nodejs-app
deployment "nodejs-app" successfully rolled out

igorc@igor-laptop:~$ kubectl describe deployment nodejs-app
Name:            nodejs-app
Namespace:        default
CreationTimestamp:    Sun, 02 Apr 2017 14:33:41 +1000
Labels:            app=nodejs-app
            version=latest
Annotations:        deployment.kubernetes.io/revision=1
Selector:        app=nodejs-app,version=latest
Replicas:        2 desired | 2 updated | 2 total | 2 available | 0 unavailable
StrategyType:        RollingUpdate
MinReadySeconds:    0
RollingUpdateStrategy:    1 max unavailable, 1 max surge
Pod Template:
  Labels:    app=nodejs-app
        version=latest
  Containers:
   nodejs-app:
    Image:    igoratencompass/nodejs-app:latest
    Port:   
    Requests:
      cpu:        1
      memory:        128Mi
    Environment:    <none>
    Mounts:        <none>
  Volumes:        <none>
Conditions:
  Type        Status    Reason
  ----        ------    ------
  Available     True    MinimumReplicasAvailable
OldReplicaSets:    <none>
NewReplicaSet:    <none>
Events:        <none>
```

Then we can check the deployment history for our app:

```
igorc@igor-laptop:~$ kubectl rollout history deployment/nodejs-app
deployments "nodejs-app"
REVISION    CHANGE-CAUSE
1        <none>
```

As we mentioned before each Deployment creates a [ReplicaSet](https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/) in the background which in turn creates the Pods. We can check it like:

```
igorc@igor-laptop:~$ kubectl describe rs nodejs-app-750151909
Name:        nodejs-app-750151909
Namespace:    default
Selector:    app=nodejs-app,pod-template-hash=750151909,version=latest
Labels:        app=nodejs-app
        pod-template-hash=750151909
        version=latest
Annotations:    deployment.kubernetes.io/desired-replicas=2
        deployment.kubernetes.io/max-replicas=3
        deployment.kubernetes.io/revision=1
Replicas:    2 current / 2 desired
Pods Status:    2 Running / 0 Waiting / 0 Succeeded / 0 Failed
Pod Template:
  Labels:    app=nodejs-app
        pod-template-hash=750151909
        version=latest
  Containers:
   nodejs-app:
    Image:    igoratencompass/nodejs-app:latest
    Port:   
    Requests:
      cpu:        1
      memory:        128Mi
    Environment:    <none>
    Mounts:        <none>
  Volumes:        <none>
Events:            <none>
```

### Deploying new version of the app

Lets say we have issued a new Docker image containing the new version of our app:

```
$ kubectl set image deployment/nodejs-app:1.0.1
$ kubectl rollout status deployment/nodejs-app
```

so by just changing the image version we have deployed our new application in a way specified in the Deployment YAML file we initially submitted.

### Rolling back

To roll back the last deployment:

```
$ kubectl rollout undo deployment/nodejs-app
```

To roll back to specific previous deployment:

```
$ kubectl rollout undo deployment/nodejs-app --to-revision=2
```

We can pause and resume a deployment too:

```
$ kubectl rollout pause ...
$ kubectl rollout resume ...
```

### Service VIP and DNS

Since we deployed our nodejs-app (very simple app that just prints the name of the host it is running on, which in this case will be the Pod name) as a Service it will get VIP assigned that other pods in the Namespace can resolve via a FQDN DNS name of `nodejs-app.default.svc.cluster.local` or just by its short name of `nodejs-app` via the internal DNS service created by Kubernetes. If we log in the apache pod I created for a load test and query our app from there:

```
root@php-apache-3815965786-kzs59:/var/www/html# cat /etc/resolv.conf
search default.svc.cluster.local svc.cluster.local cluster.local eu-west-1.compute.internal tftest.encompasshost.internal consul
nameserver 100.64.0.10
options ndots:5
 
root@php-apache-3815965786-kzs59:/var/www/html# for i in `seq 1 7`; do curl http://nodejs-app; done
I am: nodejs-app-750151909-5frt4
I am: nodejs-app-750151909-7gzt5
I am: nodejs-app-750151909-7gzt5
I am: nodejs-app-750151909-5frt4
I am: nodejs-app-750151909-7gzt5
I am: nodejs-app-750151909-5frt4
I am: nodejs-app-750151909-7gzt5
```

we can see how the requests are being round-robined between both pods we have running for our app. To further test DNS resolution we can start temporary image that has the `dnsutils` package installed, like `busybox` for example:

```
igorc@igor-laptop:~$ kubectl run -i --tty --image busybox dns-test --restart=Never --rm /bin/sh
If you don't see a command prompt, try pressing enter.
/ # nslookup nodejs-app
Server:    100.64.0.10
Address 1: 100.64.0.10 kube-dns.kube-system.svc.cluster.local
 
Name:      nodejs-app
Address 1: 100.70.56.10 nodejs-app.default.svc.cluster.local
/ #
```

### Service configuration with ConfigMaps

Kubernetes offers a very convenient way of storing the service configuration internally via [ConfigMaps](https://kubernetes.io/docs/tasks/configure-pod-container/configmap/). For example, the following ConfigMap holds the configuration parameters for a Redis server:

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: example-redis-config
  namespace: default
data:
  redis-config: |
    maxmemory 2mb
    maxmemory-policy allkeys-lru
```

that the service/pod can then consume as:

```
apiVersion: v1
kind: Pod
metadata:
  name: redis
spec:
  containers:
  - name: redis
    image: kubernetes/redis:v1
    env:
    - name: MASTER
      value: "true"
    ports:
    - containerPort: 6379
    resources:
      limits:
        cpu: "0.1"
    volumeMounts:
    - mountPath: /redis-master-data
      name: data
    - mountPath: /redis-master
      name: config
  volumes:
    - name: data
      emptyDir: {}
    - name: config
      configMap:
        name: example-redis-config
        items:
        - key: redis-config
          path: redis.conf
```

This is a very convenient way of separating the configuration from the application binary and have them both checked out and version-ed in Git. There is a new construct called envFrom coming in Kubernetes 1.6 which can be used as shown below:

```
envFrom:
  - configMapRef:
      name: example-redis-config
```

to consume all the variables from the ConfigMap in one go.

### Autoscaling

K8s has a [HorizontalPodAutoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) for this purpose. By adding:

```
---
apiVersion: autoscaling/v1
kind: HorizontalPodAutoscaler
metadata:
  name: nodejs-app-autoscaler
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: extensions/v1beta1
    kind: Deployment
    name: nodejs-app-deployment
  minReplicas: 3
  maxReplicas: 6
  targetCPUUtilizationPercentage: 80
```

to our `nodejs-app.yml` file we have just made our application scale up and down between 3 and 6 instances (Pods) based on the CPU utilization with threshold of 80%.

{% include series.html %}