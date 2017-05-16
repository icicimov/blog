---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes Cluster External Services'
categories: 
  - Virtualization
tags: [kubernetes, docker, containers]
date: 2017-4-14
series: "Kubernetes Cluster in AWS"
---
{% include toc %}
[Previously created Service]({{ site.baseurl }}{% post_url 2017-4-13-Kubernetes-Applications-and-Services %}) works nice but only if we have ALL our services deployed as containers which, at least at the beginning, is not going to be the case. The IP `100.70.56.10` of our nodejs-app Service is not reachable from other servers in the VPC that are external to the k8s cluster. To provide this functionality we need to expose our app as external Service. Note that "external" in this case means external to the k8s cluster, so anything inside the VPC and/or even outside the VPC, the Internet.

# Exposing Services Outside K8S Cluster

The easiest way I've found doing this is by using the [nginx-ingress-controller](https://github.com/kubernetes/ingress) and k8s [Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/) resource functionality. Simply said an Ingress is a collection of rules that allow inbound connections to reach the cluster services. It can be configured to give services externally-reachable urls, load balance traffic, terminate SSL, offer name based virtual hosting etc. Users request ingress by POSTing the Ingress resource to the API server. An [IngressController](https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-controllers) is responsible for fulfilling the Ingress, usually with a loadbalancer, though it may also configure an edge router or additional frontends to help handle the traffic in an HA manner.

Apart from exposing the services externally the Ingress also provides easy HTTPS traffic management and a single point for SSL certificate management via [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/). Another benefit is that we can easily expose the service via different access points with different features like for example use HTTPS when service is accessed from outside the VPC (Internet) but use HTTP internally which will save us hardware resources from unnecessary encoding the internal traffic.

To create a Secret that will store our Encompass certificate we put our certificate and key files under `/tmp` locally lets say and we run:

```
$ kubectl create secret tls encompass-crt --key /tmp/tls.key --cert /tmp/tls.crt
```

Or we can use `kubectl` and YAML file ie `encompass-tls-secret.yml` with `base64` encoded strings of the cert and the key:

``` 
apiVersion: v1
kind: Secret
metadata:
  name: encompass-tls-secret
  namespace: default
type: kubernetes.io/tls
data:
  tls.crt: |
    LS0tLS1...
  tls.key: |
    LS0tLS1...
```

We get the base64 strings as:

```
$ cat /tmp/tls.crt | base64
$ cat /tmp/tls.key | base64
```

Then we run:

```
$ kubectl create -f ./encompass-tls-secret.yml
```

to create the k8s resource.

The Secrets are also handy to store applications and database user-names and passwords that we can then just reference in the Deployment instead storing them in our Docker images. Note that the data in the Secrets is not encrypted but just base64 encoded.

## Install Route53 mapper add-on

Another great feature in k8s are the plug-ins. The `route53-mapper` plug-in automatically adds a Route53 record for an ELB for us when ever one gets created for a service. This should enable k8s to create Route53 records for the service ELB's:

```
igorc@igor-laptop:~$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/route53-mapper/v1.2.0.yml
deployment "route53-mapper" created
```

This is a Kubernetes service that polls services (in all namespaces) that are configured with the label `dns=route53` and adds the appropriate alias to the domain specified by the `annotation` (for example `domainName=sub.mydomain.io`). Multiple domains and top level domains are also supported: `domainName=.mydomain.io,sub1.mydomain.io,sub2.mydomain.io`. Example:

```
apiVersion: v1
kind: Service
metadata:
  name: my-app
  labels:
    app: my-app
    role: web
    dns: route53
  annotations:
    domainName: "my-app.mydomain.com"
spec:
  selector:
    app: my-app
    role: web
  ports:
  - name: web
    port: 80
    protocol: TCP
    targetPort: web
  - name: web-ssl
    port: 443
    protocol: TCP
    targetPort: web-ssl
  type: LoadBalancer
```

An `A` record for `my-app.mydomain.com` will be created as an alias to the ELB that is configured by Kubernetes. This assumes that a hosted zone exists in Route53 for `.mydomain.com`. Any record that previously existed for that dns name will be updated.

In our concrete case we can use:

```
apiVersion: v1
kind: Service
metadata:
  name: nodejs-app
  labels:
    app: nodejs-app
    dns: route53
  annotations:
    domainName: "nodejs-app-external.encompasshost.com,nodejs-app.tftest.encompasshost.internal"
[...]
```

And have the `route53-mapper` plug-in create the records for our public and private Route53 DNS zones and point them to the appropriate ELB upon Service creation.

## Exposing services to Internet

To expose our app to the outside world via `nginx-ingress-controller` we create the following YAML file `nodejs-app_ingress_external.yml`:

```
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: test-ingress-external
  namespace: default
  annotations:
    kubernetes.io/ingress.class: 'nginx'
    ingress.kubernetes.io/limit-connections: '25'
    ingress.kubernetes.io/limit-rps: '5'
spec:
  tls:
  - hosts:
    - nodejs-app-external.encompasshost.com
    secretName: encompass-tls-secret
  rules:
  - host: nodejs-app-external.encompasshost.com
    http:
      paths:
      - path: /
        backend:
          serviceName: nodejs-app-svc
          servicePort: 80
```

where we can see us supplying the above created Secret name to the Ingress so it can access the SSL certificate and also applying some basic DoS protection via limiting the total number of connections and requests per second coming from a single IP. The annotations section is very important as it specifies the class of the Ingress Controller used, in this case `Nginx`, since there can be multiple types (classes) of Ingress Controllers running in a single k8s and Nginx is just one of them ([Traefik](https://docs.traefik.io/user-guide/kubernetes/) is also very popular one for cloud environments but lacks some of functionality provided by Nginx).

We apply it via kubectl:

```
$ kubectl create --store-config -f nodejs-app_ingress_external.yml
```

And now we just need to create the `nginx-ingress-controller`, we can download the file from the Kubernetes master Git repo and modify it to our liking, file `nginx-ingress-controller-external.yml`:

```
kind: ConfigMap
apiVersion: v1
metadata:
  namespace: default
  name: ingress-nginx-external
  labels:
    k8s-addon: ingress-nginx.addons.k8s.io
data:
  use-proxy-protocol: "true"
  enable-sticky-sessions: "false"
 
---
 
kind: Service
apiVersion: v1
metadata:
  namespace: default
  name: ingress-nginx-external
  labels:
    k8s-addon: ingress-nginx.addons.k8s.io
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: '*'
    service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout: 1800
spec:
  type: LoadBalancer
  selector:
    app: ingress-nginx-external
  ports:
  - name: http
    port: 80
    targetPort: http
  - name: https
    port: 443
    targetPort: https
 
---
 
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  namespace: default
  name: ingress-nginx-external
  labels:
    k8s-addon: ingress-nginx.addons.k8s.io
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: ingress-nginx-external
        k8s-addon: ingress-nginx.addons.k8s.io
    spec:
      terminationGracePeriodSeconds: 60
      containers:
      - image: gcr.io/google_containers/nginx-ingress-controller:0.9.0-beta.3
        name: ingress-nginx-external
        imagePullPolicy: Always
        ports:
          - name: http
            containerPort: 80
            protocol: TCP
          - name: https
            containerPort: 443
            protocol: TCP
        livenessProbe:
          httpGet:
            path: /healthz
            port: 10254
            scheme: HTTP
          initialDelaySeconds: 30
          timeoutSeconds: 5
        env:
          - name: POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: POD_NAMESPACE
            valueFrom:
              fieldRef:
                fieldPath: metadata.namespace
        args:
        - /nginx-ingress-controller
        - --default-backend-service=$(POD_NAMESPACE)/nginx-default-backend
        - --configmap=$(POD_NAMESPACE)/ingress-nginx-external
        - --publish-service=$(POD_NAMESPACE)/ingress-nginx-external
        - --watch-namespace=$(POD_NAMESPACE)
```

All details about customizing the controller and its parameters are available in the excellent documentation at [Customizing NGINX](https://github.com/kubernetes/ingress/blob/master/controllers/nginx/configuration.md) in the Kubernetes GitHub repository.

And we apply it:

```
$ kubectl create --store-config -f nginx-ingress-controller-external.yml
```

What happens then is Kubernetes creates a Nginx Service exposed on port 80 and 443 and an ELB in our VPC pointing to it. It also enables the proxy-protocol on the ELB (and the Nginx controller Pods of course) by default so the client IP is not lost ie we see the real client IP hitting our service and not the ELB's internal one.

What's left for me is creating an `A ALIAS` record (if not created by the route53-mapper plug-in) for `nodejs-app-external.encompasshost.com` in our public DNS zone and pointing it to the ELB. Now I can access my app from anywhere:

```
igorc@silverstone:~$ dig +short nodejs-app-external.encompasshost.com
52.51.142.202
52.19.176.124
52.16.220.146

igorc@silverstone:~$ curl -v -ksSNL -X GET https://nodejs-app-external.encompasshost.com
* Rebuilt URL to: https://nodejs-app-external.encompasshost.com/
*   Trying 52.51.142.202...
* Connected to nodejs-app-external.encompasshost.com (52.51.142.202) port 443 (#0)
* found 173 certificates in /etc/ssl/certs/ca-certificates.crt
* found 721 certificates in /etc/ssl/certs
* ALPN, offering http/1.1
* SSL connection using TLS1.2 / ECDHE_RSA_AES_128_GCM_SHA256
*      server certificate verification SKIPPED
*      server certificate status verification SKIPPED
*      common name: *.encompasshost.com (matched)
*      server certificate expiration date OK
*      server certificate activation date OK
*      certificate public key: RSA
*      certificate version: #3
*      subject: C=AU,ST=New South Wales,L=Sydney,O=Encompass Corporation Pty Ltd,CN=*.encompasshost.com
*      start date: Wed, 06 Apr 2016 00:00:00 GMT
*      expire date: Mon, 30 Apr 2018 12:00:00 GMT
*      issuer: C=US,O=DigiCert Inc,CN=DigiCert SHA2 Secure Server CA
*      compression: NULL
* ALPN, server accepted to use http/1.1
> GET / HTTP/1.1
> Host: nodejs-app-external.encompasshost.com
> User-Agent: curl/7.47.0
> Accept: */*
>
< HTTP/1.1 200 OK
< Server: nginx/1.11.10
< Date: Thu, 27 Apr 2017 06:50:25 GMT
< Content-Type: text/plain
< Transfer-Encoding: chunked
< Connection: keep-alive
< Strict-Transport-Security: max-age=15724800; includeSubDomains; preload
<

I am: nodejs-app-deployment-1673444943-r24kz

* Connection #0 to host nodejs-app-external.encompasshost.com left intact
```

We can see the connection working and can confirm from the output the certificate is working as well. By default the Nginx ingress controller re-directs the HTTP traffic to HTTPS so I don't need to do anything in that matter:

```
igorc@silverstone:~$ curl -ksSNIL -X GET http://nodejs-app-external.encompasshost.com
HTTP/1.1 301 Moved Permanently
Server: nginx/1.11.10
Date: Thu, 27 Apr 2017 06:53:08 GMT
Content-Type: text/html
Content-Length: 186
Connection: keep-alive
Location: https://nodejs-app-external.encompasshost.com/
Strict-Transport-Security: max-age=15724800; includeSubDomains; preload
 
HTTP/1.1 200 OK
Server: nginx/1.11.10
Date: Thu, 27 Apr 2017 06:53:10 GMT
Content-Type: text/plain
Transfer-Encoding: chunked
Connection: keep-alive
Strict-Transport-Security: max-age=15724800; includeSubDomains; preload
```

So just by creating a Secret, a Nginx ingress controller and a simple Ingress I have exposed my application to the world, load-balanced and secured via SSL:

```
igorc@silverstone:~$ for i in `seq 1 7`; do curl -ksSNL -X GET https://nodejs-app-external.encompasshost.com; done
I am: nodejs-app-deployment-1673444943-q708f
I am: nodejs-app-deployment-1673444943-r24kz
I am: nodejs-app-deployment-1673444943-r24kz
I am: nodejs-app-deployment-1673444943-dv6k7
I am: nodejs-app-deployment-1673444943-q708f
I am: nodejs-app-deployment-1673444943-dv6k7
I am: nodejs-app-deployment-1673444943-q708f
```

We can see the requests load-balnced between our app Pods in the exposed Service.

Now one major point to make here. If we look back in the Ingress we created we can see that the application is chosen based on the Host header in the client request. This means we can simply add another host to the same Ingress controller pointing to a different service in our k8s cluster:

```
[...]
  - host: another-app.encompasshost.com
    http:
      paths:
      - path: /
        backend:
          serviceName: another-app-svc
          servicePort: 80
```

and we got our self multi-host Nginx SSL load-balancer and reverse proxy for many backand services using the same or different TCP port. We can keep adding applications in this manner and scale up our Nginx controller (by increasing the replicas number) if necessary to handle more traffic. This is also big money saver since we don't have to run a separate ELB for each service we create.

Another useful functionality of the Ingress resource is providing authentication via annotations. For example adding the following to the annotations section of our Ingress:

```
[...]
  annotations:
    # type of authentication
    ingress.kubernetes.io/auth-type: basic
    # name of the secret that contains the user/password definitions
    ingress.kubernetes.io/auth-secret: basic-auth
[...]
```

will provide Basic authentication for our app via username and password stored in a Secret resource.

## Exposing services internally to VPC

For this case we need to make one single change to the ingress-nginx Service and turn the Nginx ingress controller into internal-only:

```
[...]
kind: Service
apiVersion: v1
metadata:
  name: ingress-nginx
  labels:
    k8s-addon: ingress-nginx.addons.k8s.io
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: '*'
    service.beta.kubernetes.io/aws-load-balancer-internal: '0.0.0.0/0'    # to create internal ELB
spec:
  type: LoadBalancer
  selector:
    app: ingress-nginx
  ports:
  - name: http
    port: 80
    targetPort: http
  - name: https
    port: 443
    targetPort: https
[...]
```

Everything else said above applies here as well except Kubernetes will create an ELB of type Internal accessible only from inside the VPC.

As we said before though, we don't need SSL in this case so we can modify our Ingress as well to drop it and let Nginx know we don't need HTTP to HTTPS redirect:

```
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: test-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: 'nginx'
    ingress.kubernetes.io/ssl-redirect: 'false'
spec:
  rules:
  - host: nodejs-app.encompasshost.com
    http:
      paths:
      - path: /
        backend:
          serviceName: nodejs-app-svc
          servicePort: 80
```

After creating an A ALIAS record for nodejs-app in our VPC internal DNS zone we can access the app by going to http://nodejs-app from any of our VPC servers just like we access it from within the k8s cluster.

## Authentication

There might be instances when we want to protect the service access with user credentials, for example when accessing monitoring dashboard lets say or other sensitive data. Kubernetes offers built-in options for user authentication and one of them is Basic Authentication via Secrets. Lets create `htpasswd` file with user `someuser` and password `somepassword` (not the real credentials used of course):

```
$ htpasswd -c auth someuser
New password:
Re-type new password:
Adding password for user someuser
```

Now we create a Secret for this file in k8s:

```
$ kubectl create secret generic basic-auth --from-file=auth -n default
secret "basic-auth" created
```

and check the result:

```
$ kubectl get secret basic-auth -o yaml --export -n default
apiVersion: v1
data:
  auth: ZXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXK
kind: Secret
metadata:
  creationTimestamp: null
  name: basic-auth
  selfLink: /api/v1/namespaces//secrets/basic-auth
type: Opaque
```

Now with this configured we can protect our nodejs-app if necessary with this credentials by adding the following annotations to the Ingress for the service:

```
[...]
  annotations:
    # type of authentication
    ingress.kubernetes.io/auth-type: basic
    # name of the secret that contains the user/password definitions
    ingress.kubernetes.io/auth-secret: basic-auth
    # message to display with an appropiate context why the authentication is required
    ingress.kubernetes.io/auth-realm: "Authentication Required"
[...]
```

Another option apart from the basic annotation are the `auth-url` and `auth-signin` annotations which allow us to use an external authentication provider to protect our Ingress resources. Example for using `Auth0` for external authentication would be:

```
[...]
metadata:
  name: application
  annotations:
    "ingress.kubernetes.io/auth-url": "https://$host/oauth2/auth"
    "ingress.kubernetes.io/signin-url": "https://$host/oauth2/sign_in"
[...]
```

More in depth details about this case can be find here [https://github.com/kubernetes/ingress/blob/858e3ff2354fb0f5066a88774b904b2427fb9433/examples/external-auth/nginx/README.md](https://github.com/kubernetes/ingress/blob/858e3ff2354fb0f5066a88774b904b2427fb9433/examples/external-auth/nginx/README.md).

{% include series.html %}