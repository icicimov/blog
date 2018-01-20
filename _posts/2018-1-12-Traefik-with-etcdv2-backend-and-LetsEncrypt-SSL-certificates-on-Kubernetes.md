---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: "Traefik with etcdv2 backend and Let's Encrypt SSL certificates on Kubernetes"
categories: 
  - Kubernetes
tags: ['kubernetes', 'traefik', 'letsencrypt', 'aws']
date: 2018-1-12
---

This post is an extension of a previous one [Kubernetes cluster step-by-step: Services and Load Balancing]({{ site.baseurl }}{% post_url 2017-6-19-Kubernetes-cluster-step-by-step-Part8 %})) about Traefik and its usage in Kubernetes. This time I'm trying to use the `etcd` KV store as backend since Traefik has support for it and also use Traefik to manage the SSL certificates for my applications via Let's Encrypt and its built in lego support. I hope with all this setup I can run Traefik in multiple Pods for High Availability and load sharing in production clusters. 

## Populate the etcd KV store

First we create a ConfigMap to store the Traefik configuration in our cluster.

```
# traefik-cm.yml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: traefik-external-ingress-proxy-config
  namespace: default
data:
  traefik.toml: |-
    logLevel = "DEBUG"
    debug = true
    defaultEntryPoints = ["http", "https"]

    [entryPoints]
      [entryPoints.http]
      address = ":80"
      compress = true
      [entryPoints.http.redirect]
      entryPoint = "https"
      [entryPoints.https]
      address = ":443"
      [entryPoints.https.tls]
      MinVersion = "VersionTLS12"
      CipherSuites = ["TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA", "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA", "TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA", "TLS_RSA_WITH_AES_128_GCM_SHA256", "TLS_RSA_WITH_AES_256_GCM_SHA384", "TLS_RSA_WITH_AES_128_CBC_SHA", "TLS_RSA_WITH_AES_256_CBC_SHA"]
      [[entryPoints.https.tls.certificates]]
      CertFile = "/ssl/tls.crt"
      KeyFile = "/ssl/tls.key"

    [etcd]
    endpoint = "192.168.0.151:2379,192.168.0.152:2379,192.168.0.153:2379"
    watch = true
    prefix = "/traefik"

    [acme]
    email = "myuser@mycompany.com"
    storage = "traefik/acme/account"
    storageFile = "/acme/acme.json"
    entryPoint = "https"
    onHostRule = true
    #onDemand = true
    acmeLogging = true
    # For Staging, comment out to go to Prod
    caServer = "https://acme-staging.api.letsencrypt.org/directory"
    # DNS-01 challenge
    dnsProvider = "route53"
    [[acme.domains]]
    main = "office.mydomain.com"
    sans = ["nodejs-app.office.mydomain.com", "encompass.office.mydomain.com"]

    [web]
    address = ":8080"
    readOnly = true
    # enable basic authentication
      [web.auth.basic]
        users = ["myuser:$apr1$k2qslCn6$0OgA8vhnyC8nJ99YfJMOM/"]

    [kubernetes]
    # only monitor Ingresses with this label
    labelselector = "public-lb=traefik"
``` 

The config sets the etcd end points and the ACME details for obtaining the SSL certificates from LE.

We have debug mode enabled and ACME client (lego) pointed to LE staging server for the testing stage. When confident it all works point to production and reduce the log verbosity. 

We also tell Traefik we want to use `DNS-01` for ACME challenge and that our DNS provider is `Route53`, my cluster DNS zone is hosted in AWS. 

We apply the manifest:

```
kubectl apply -f traefik-cm.yml
```

Next we create a `Job` that we'll use traefik's `storeconfig` command as per [Key-value store configuration](https://docs.traefik.io/user-guide/kv-config/) documentation to populate the `etcd` backend (my cluster has etcd v2) and the above `ConfigMap` to get the settings from:

```
# traefik-config-job.yml
---
apiVersion: batch/v1
kind: Job
metadata:
  #name: traefik-etcd-config
  generateName: traefik-etcd-config
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 100
  template:
    metadata:
      name: traefik-etcd-config
    spec:
      containers:
      - name: storeconfig
        image: traefik:v1.5.0-rc3
        imagePullPolicy: IfNotPresent
        args: [ "storeconfig", "-c", "/etc/traefik/traefik.toml" ]
        volumeMounts:
        - name: config
          mountPath: /etc/traefik
          readOnly: true
        - name: ssl
          mountPath: /etc/ssl
          readOnly: true
        - name: tls
          mountPath: /ssl
          readOnly: true
        - name: acme
          mountPath: /acme/acme.json
      restartPolicy: Never
      volumes:
      - name: ssl
        hostPath:
          path: /etc/ssl
      - name: tls
        secret:
          secretName: traefik-cert
      - name: config
        configMap:
          name: traefik-external-ingress-proxy-config
      - name: acme
        hostPath:
          path: /acme/acme.json
```

This Job needs to be run only once. Replace the `traefik:v1.5.0-rc3` image with the latest one published by Traefik team if needed.

Apply the manifest:

```
kc apply -f traefik-config-job.yml
```

and then check on the etcd nodes if the store has been successfully populated:

```
etcdctl ls traefik --recursive
etcdctl ls traefik --recursive | wc -l
94
```

In my case, Traefik Job created 94 entries. If something went wrong, check with:

```
kc get jobs
kc get pods --show-all
```

and confirm the Job's pod completed successfully, or you need to start over delete the keys from one of the etcd nodes:

```
etcdctl rm traefik --recursive
```

fix your issue and re-apply the Job. Note that I'm using the `generateName` meta tag instead of `name` that enables me to run the same Job multiple times without deleting the previous one first; every time applied the Job will get a new unique name that will not clash with the previous one.

## Prepare for DNS-01 ACME challenge

Traefik Pod(s) will need access to my Route53 hosted Zone for which I need to create IAM user and attach an appropriate policy to it. I create the following [Lego recommended](https://github.com/xenolf/lego/blob/master/README.md#aws-route-53) IAM policy to enable `lego` modify (upsert) Zone records:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListZones",
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZonesByName",
                "route53:GetChange"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Sid": "EditZone",
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/<MY_HOSTED_ZONE_ID>"
            ]
        }
    ]
}
```

and attached it to the new user `TRAEFIK_LE_USER` I created. Then I create a `Secret` in my cluster that will hold the AWS access keys for the above user:

```
# traefik-aws-dns-secret.yml
---
apiVersion: v1
kind: Secret
metadata:
  name: aws-le-dns-acc
  namespace: default
type: Opaque
data:
  # echo -n 'KEY' | base64
  aws-key: <AWS_KEY_BASE64>
  aws-secret-key: <AWS_SECRET_KEY_BASE64>
```

The keys need to be `base64` encoded first before used in the manifest. Applying the manifest will create new secret `aws-le-dns-acc` that I can use to get the credentials from in the Traefik `Deployment` manifest.

## Running Traefik

Now that we have the store successfully populated and our IAM credentials sorted out we can deploy the Traefik pod. Here is my manifest:

```
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: traefik-external-ingress-proxy
  namespace: default
  labels:
    app: traefik-external-ingress-proxy
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: traefik-external-ingress-proxy
      name: traefik-external-ingress-proxy
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
    type: RollingUpdate
  template:
    metadata:
      labels:
        app: traefik-external-ingress-proxy
        name: traefik-external-ingress-proxy
    spec:
      terminationGracePeriodSeconds: 60
      serviceAccountName: traefik-ingress-controller
      containers:
      - name: traefik-ingress-lb
        image: igoratencompass/traefik-alpine:v1.5.0-rc3
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            cpu: 200m
            memory: 2000Mi
          requests:
            cpu: 50m
            memory: 50Mi
        env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef:
              name: aws-le-dns-acc
              key: aws-key
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef:
              name: aws-le-dns-acc
              key: aws-secret-key
        - name: AWS_REGION
          value: "ap-southeast-2"
        ports:
        - containerPort: 80
        - containerPort: 443
        - containerPort: 8080
        args:
        - --web
        - --kubernetes
        - --etcd
        - --etcd.endPoint="192.168.0.151:2379,192.168.0.152:2379,192.168.0.153:2379"
        volumeMounts:
        - mountPath: /etc/ssl
          name: ssl
          readOnly: true
        - mountPath: /ssl
          name: tls
          readOnly: true
        - mountPath: /etc/traefik
          name: config
          readOnly: true
        - mountPath: /acme/acme.json
          name: acme
      volumes:
      - hostPath:
          path: /etc/ssl
          type: ""
        name: ssl
      - name: tls
        secret:
          defaultMode: 420
          secretName: traefik-cert
      - configMap:
          defaultMode: 420
          name: traefik-external-ingress-proxy-config
        name: config
      - hostPath:
          path: /acme/acme.json
          type: ""
        name: acme
```

First thing to note is I'm using my own Alpine based Traefik image `igoratencompass/traefik-alpine:v1.5.0-rc3` that has `bash` and `dns utilitiess` installed. This showed handy in troubleshooting various issues. The rest is common Deployment stuff, we just need to point the Pod to the etcd endpoints from where it needs to pickup its configuration and store the ACME certificates. The `traefik-ingress-controller` ServiceAccount used has been created via the following manifest:

```
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-ingress-controller
  namespace: default

---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
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
      - ""
    resources:
      - configmaps
    resourceNames:
      - "traefik-external-ingress-proxy-config"
    verbs:
      - get
      - update
  - apiGroups:
      - extensions
    resources:
      - ingresses
    verbs:
      - get
      - list
      - watch

---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: traefik-ingress-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-ingress-controller
subjects:
- kind: ServiceAccount
  name: traefik-ingress-controller
  namespace: default

```

## Testing

Right off the bat I'm facing this show stopper issue:

```
time="2018-01-12T03:50:49Z" level=error msg="Error getting ACME certificate for domain [office.mydomain.com nodejs-app.office.mydomain.com encompass.office.mydomain.com]: Cannot obtain certificates map[office.mydomain.com:Error presenting token: Failed to determine Route 53 hosted zone ID: Could not find the start of authority nodejs-app.office.mydomain.com:Error presenting token: Failed to determine Route 53 hosted zone ID: Could not find the start of authority encompass.office.mydomain.com:Error presenting token: Failed to determine Route 53 hosted zone ID: Could not find the start of authority]+v"
```

which doesn't make much sense since I can successfully resolve the Zone's SOA record just fine from inside the Traefik Pod (this is where the custom Alpine image comes handy):

```
$ kc get pods -o wide
NAME                                              READY     STATUS    RESTARTS   AGE       IP          NODE
dnstools                                          1/1       Running   0          4m        10.2.43.2   k9s01.virtual.local
traefik-external-ingress-proxy-7f996f4f44-s592j   1/1       Running   0          12m       10.2.50.4   k9s02.virtual.local

$ kc exec -ti traefik-external-ingress-proxy-7f996f4f44-s592j -- bash
bash-4.3# dig +short -t ns office.mydomain.com
ns-229.awsdns-28.com.
ns-1245.awsdns-27.org.
ns-1701.awsdns-20.co.uk.
ns-814.awsdns-37.net.
bash-4.3# dig +short -t soa @ns-229.awsdns-28.com. office.mydomain.com
ns-814.awsdns-37.net. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
```

I also confirmed that the IAM policy attached works by installing the AWS keys and `awscli` tool on one of the nodes and checking the Zone access with this user's credentials:

```
root@k9s01:~# aws route53 list-resource-record-sets --hosted-zone-id <MY_HOSTED_ZONE_ID> --out text
RESOURCERECORDSETS  office.mydomain.com. 172800  NS
RESOURCERECORDS ns-814.awsdns-37.net.
RESOURCERECORDS ns-1701.awsdns-20.co.uk.
RESOURCERECORDS ns-229.awsdns-28.com.
RESOURCERECORDS ns-1245.awsdns-27.org.
RESOURCERECORDSETS  office.mydomain.com. 900 SOA
RESOURCERECORDS ns-814.awsdns-37.net. awsdns-hostmaster.amazon.com. 1 7200 900 1209600 86400
```

Making IAM policy even more permissive like:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListZones",
            "Effect": "Allow",
            "Action": [
                "route53:List*",
                "route53:Get*"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Sid": "EditZone",
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/<MY_HOSTED_ZONE_ID>"
            ]
        }
    ]
}
```

did not make any difference. I had an [issue](https://github.com/containous/traefik/issues/2699) opened about this but it got closed so no idea how to solve this one.

Other issues I found during the tests are captured by [Issue #2670](https://github.com/containous/traefik/issues/2670) and [Issue #2671](https://github.com/containous/traefik/issues/2671). I noticed that Traefik is not retrying the ACME CA server connection upon failure, meaning if you have some connectivity or DNS issues in the cluster at the moment the Pod is launched you will never get any certificates issued. Another thing was the ACME locking. In case you launch multiple Traefik Pods for High Availability one of them will set a lock in a key in the KV store and start managing the certificates. However, if that Pod dies or gets deleted the lock is left behind thus preventing the others (including the replacement one launched) from obtaining the lock. To make things worse, after an initial try the Pods give up and never try again (based on my logs observation, did not have time to look in the code) thus rendering the ACME unusable. Seems like the code is lacking a lock checking loop and some kind of mechanism to deal with stale locks.

## Conclusion

Traefik is no doubt a great piece of software, super light and reach with features. The question is, does it currently have everything it needs to be employed in production K8S cluster especially when ACME is a requirement? From what I can see the answer is `no`. Apart from the issues I saw it lacks a native integration with Kubernetes elements like `Secrets` and `ConfigMaps`. The [Proposal: Native Kubernetes LetsEncrypt Implementation](https://github.com/containous/traefik/issues/2542) looks promising and is a move in the right direction in terms of K8S integration. I also have a feeling, and I'm sorry to say this since I know the Traefik developers are  working hard, that for now the Kubernetes usage case is a second class citizen when it comes to features and integration. Probably the team is overwhelmed with issues and more focused on other areas and I hope this to change very soon so Traefik gets the spot it deserves in the world of Kubernetes.
