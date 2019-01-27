---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes HPA Autoscaling with Custom Metrics'
categories: 
  - Kubernetes
tags: ['kubernetes']
date: 2018-10-10
---

The initial [Horizontal Pod Autoscaler](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/) was limited in features and it only supported scaling deployments based on CPU metrics. The most recent Kubernetes releases included support for Memory, multiple metrics and in the latest version Custom Metrics. This is what we explore here since it can enable our apps to scale on other metrics but RAM and CPU like average number of http requests lets say or depth of an JMS queue or any other custom metric we collect in Prometheus.

## Kops Setup

The changes we need to make to enable API versions required to support scaling on cpu, memory and custom metrics:

* Enable the `autoscaling/v2beta1` API in the API server for K8s 1.8 and 1.9

  ```yaml
  spec:
    kubeAPIServer:
      runtimeConfig:
        autoscaling/v2beta1: "true"
  ```

* Enable gathering custom metrics

  ```yaml
  spec:
    kubelet:
      enableCustomMetrics: true
  ```

* The last component needed, the [Aggregation API](https://v1-9.docs.kubernetes.io/docs/tasks/access-kubernetes-api/configure-aggregation-layer/) is enabled by default by Kops

## Kubernetes Metrics Server

Next we need to install the [Custom Metrics Server](https://github.com/kubernetes/kops/blob/master/addons/metrics-server/README.md). We can install it as [Kops Addon](https://github.com/kubernetes/kops/blob/master/addons/metrics-server/README.md):

```bash
# Kubernetes 1.8+
$ kubectl apply -f https://raw.githubusercontent.com/kubernetes/kops/master/addons/metrics-server/v1.8.x.yaml
```

It also has a stable HELM Chart so we can deploy from there too:

```bash
$ helm search metrics-server
NAME                     CHART VERSION    APP VERSION    DESCRIPTION                                      
stable/metrics-server    2.0.2            0.3.0          Metrics Server is a cluster-wide aggregator of ...
```

## Custom Metrics Adapter

I've come across couple of these but used the [Prometheus Adapter](https://github.com/DirectXMan12/k8s-prometheus-adapter/) since we already run Prometheus in our clusters. Before we start we can see no metrics are available at the API point:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1" | jq
Error from server (NotFound): the server could not find the requested resource
```

The `PrometheusAdapter` also has a stable Helm Chart. We need to set the `prometheus.url` parameter in order to point the PrometheusAdapter to our Prometheus Service:

```bash
$ kubectl get svc -n monitoring
NAME                     TYPE           CLUSTER-IP       EXTERNAL-IP        PORT(S)                      AGE
alertmanager-main        NodePort       100.65.130.151   <none>             9093:30903/TCP               1y
alertmanager-operated    ClusterIP      None             <none>             9093/TCP,6783/TCP            1y
grafana                  NodePort       100.71.196.178   <none>             3000:30902/TCP               1y
ingress-nginx-external   LoadBalancer   100.65.240.159   ae2e42d2f32fa...   80:30943/TCP,443:31292/TCP   1y
kube-state-metrics       ClusterIP      100.66.134.7     <none>             8080/TCP                     1y
nginx-default-backend    ClusterIP      100.67.40.43     <none>             80/TCP                       1y
node-exporter            ClusterIP      None             <none>             9100/TCP                     1y
prometheus-k8s           NodePort       100.64.156.238   <none>             9090:30900/TCP               1y
prometheus-operated      ClusterIP      None             <none>             9090/TCP                     1y
prometheus-operator      ClusterIP      100.69.86.172    <none>             8080/TCP                     265d
```

Now after we confirmed the name of our Prometheus service is `prometheus-k8s` we run Helm:

```bash
$ helm install --name prometheus-adapter --set image.tag=v0.2.1,rbac.create=true,prometheus.url=http://prometheus-k8s.monitoring.svc.cluster.local,prometheus.port=9090 stable/prometheus-adapter
```

After a minute or two if we run the same command to check the API point we will get a huge number of metrics available via the `PrometheusAdapter`. Now we can use our go-app test app that provides Prometheus metrics to test the Autoscaling on custom metrics i.e. anything that is not Memory or CPU. The example walk-through on the `PrometheusAdapter` docs page gives an example based on the `http_requests` metrics and since our app provides the same already that is the metric we gonna use too.

First we need to tell prometheus-adapter how to collect specific metric for us. Edit the prometheus-adapter `ConfigMap` in the `default` namespace and add a new `seriesQuery` at the top of the `rules: ` section:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app: prometheus-adapter
    chart: prometheus-adapter-v0.1.2
    heritage: Tiller
    release: prometheus-adapter
  name: prometheus-adapter
data:
  config.yaml: |
    rules:
    - seriesQuery: 'http_requests_total{kubernetes_namespace!="",kubernetes_pod_name!=""}'
      resources:
        overrides:
          kubernetes_namespace: {resource: "namespace"}
          kubernetes_pod_name: {resource: "pod"}
      name:
        matches: "^(.*)_total"
        as: "${1}_per_second"
      metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
...
```

The rule will collect average rate of `http_requests` across all pods for the service over interval of 2 minutes. If we now testing against our `go-app` deployment:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/services/go-app-svc/http_requests" | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/services/go-app-svc/http_requests"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Service",
        "name": "go-app-svc",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T03:16:17Z",
      "value": "600m"
    }
  ]
}
```

we can see we already have some metrics available for the `Service` as sum of all pods in the API, but also for each of the pods separately:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests" | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/%2A/http_requests"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dgqrz",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T03:13:24Z",
      "value": "199m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dszdw",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T03:13:24Z",
      "value": "200m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-z8kb2",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T03:13:24Z",
      "value": "200m"
    }
  ]
```

Last is setting up the `HPA` (Horizontal Pod Autoscaler) for our deployment:

```yaml
# go-app-hpa-v2.yml
---
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: go-app
spec:
  scaleTargetRef:
    # point the HPA at the sample application
    # you created above
    #apiVersion: apps/v1
    apiVersion: extensions/v1beta1
    kind: Deployment
    name: go-app-deployment
  minReplicas: 3
  maxReplicas: 6
  metrics:
  # use a "Pods" metric, which takes the average of the
  # given metric across all pods controlled by the autoscaling target
  - type: Pods
    pods:
      # use the metric that you used above: pods/http_requests
      metricName: http_requests
      # target 500 milli-requests per second,
      # which is 1 request every two seconds
      targetAverageValue: 500m
```

We apply the manifest:

```bash
$ kubectl apply -f go-app-hpa-v2.yml
horizontalpodautoscaler.autoscaling "go-app-hpa-v2" created
```

and delete the old existing HPA that was based on the CPU metric:

```bash
$ kubectl delete hpa go-app-autoscaler
horizontalpodautoscaler.autoscaling "go-app-autoscaler" deleted
```

If we check a minute later we can see the new HPA has picked up on the metrics for our go-app-deployment deployment and established the needed number of pods:

```bash
$ kubectl get hpa
NAME                      REFERENCE                            TARGETS            MINPODS   MAXPODS   REPLICAS   AGE
go-app-hpa-v2             Deployment/go-app-deployment         200m/500m          3         6         3          3m
app1-autoscaler           Deployment/app1-deployment           0%/80%             1         6         1          302d
app2-autoscaler           Deployment/app2-deployment           0%/80%             1         3         1          229d
...
```

We can notice how the TARGETS for this one is different from the existing ones based on CPU metric.

```bash
$ kubectl describe hpa go-app-hpa-v2
Name:                       go-app-hpa-v2
Namespace:                  default
Labels:                     <none>
Annotations:                app=go-app
                            kubectl.kubernetes.io/last-applied-configuration={"apiVersion":"autoscaling/v2beta1","kind":"HorizontalPodAutoscaler","metadata":{"annotations":{"app":"go-app"},"name":"go-app-hpa-v2","namespace":"def...
CreationTimestamp:          Tue, 09 Oct 2018 14:49:43 +1100
Reference:                  Deployment/go-app-deployment
Metrics:                    ( current / target )
  "http_requests" on pods:  200m / 500m
Min replicas:               3
Max replicas:               6
Conditions:
  Type            Status  Reason            Message
  ----            ------  ------            -------
  AbleToScale     True    ReadyForNewScale  the last scale time was sufficiently old as to warrant a new scale
  ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count from pods metric http_requests
  ScalingLimited  True    TooFewReplicas    the desired replica count is more than the maximum replica count
Events:           <none>
```

## Testing

If we now launch some load on the service by running the below loop in multiple instances:

```bash
$ while true; do curl -sSNL https://go-app.k8s.domain.com/ | grep http_requests_total; done
```

we can see the HPA picking up the increasing requests stats:

```bash
$ kubectl describe hpa go-app-hpa-v2
Name:                       go-app-hpa-v2
...
  "http_requests" on pods:  245m / 500m
Min replicas:               3
Max replicas:               6
Conditions:
  Type            Status  Reason            Message
  ----            ------  ------            -------
  AbleToScale     True    ReadyForNewScale  the last scale time was sufficiently old as to warrant a new scale
  ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count from pods metric http_requests
  ScalingLimited  True    TooFewReplicas    the desired replica count is more than the maximum replica count
Events:           <none>
```

via the API serer:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests" | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/%2A/http_requests"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dgqrz",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:09:01Z",
      "value": "310m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dszdw",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:09:01Z",
      "value": "307m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-z8kb2",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:09:01Z",
      "value": "317m"
    }
  ]
}
```

Until we hit the limit of 500m we set in the HPA:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests" | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/%2A/http_requests"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dgqrz",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:14:16Z",
      "value": "693m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dszdw",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:14:16Z",
      "value": "700m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-z8kb2",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:14:16Z",
      "value": "689m"
    }
  ]
}
```

We can see HPA detected the threshold has been crossed:

```bash
$ kubectl describe hpa go-app-hpa-v2
Name:                       go-app-hpa-v2
...
Metrics:                    ( current / target )
  "http_requests" on pods:  528m / 500m
Min replicas:               3
Max replicas:               6
Conditions:
  Type            Status  Reason              Message
  ----            ------  ------              -------
  AbleToScale     False   BackoffBoth         the time since the previous scale is still within both the downscale and upscale forbidden windows
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from pods metric http_requests
  ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  SuccessfulRescale  2m    horizontal-pod-autoscaler  New size: 4; reason: pods metric http_requests above target
```

and launched a new pod to help with the load:

```bash
$ kubectl get pods -l app=go-app
NAME                                 READY     STATUS    RESTARTS   AGE
go-app-deployment-7f8d8bcbbc-dgqrz   1/1       Running   0          1h
go-app-deployment-7f8d8bcbbc-dszdw   1/1       Running   0          1h
go-app-deployment-7f8d8bcbbc-fmb2w   0/1       Running   0          4s
go-app-deployment-7f8d8bcbbc-z8kb2   1/1       Running   0          1h
```

We can see the new pod in the API too:

```bash
$ kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/*/http_requests" | jq .
{
  "kind": "MetricValueList",
  "apiVersion": "custom.metrics.k8s.io/v1beta1",
  "metadata": {
    "selfLink": "/apis/custom.metrics.k8s.io/v1beta1/namespaces/default/pods/%2A/http_requests"
  },
  "items": [
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dgqrz",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:15:12Z",
      "value": "710m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-dszdw",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:15:12Z",
      "value": "696m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-fmb2w",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:15:12Z",
      "value": "100m"
    },
    {
      "describedObject": {
        "kind": "Pod",
        "namespace": "default",
        "name": "go-app-deployment-7f8d8bcbbc-z8kb2",
        "apiVersion": "/__internal"
      },
      "metricName": "http_requests",
      "timestamp": "2018-10-09T04:15:12Z",
      "value": "693m"
    }
  ]
}
```

Then after we stop the load the HPA detects the new limit:

```bash
$ kubectl describe hpa go-app-hpa-v2
Name:                       go-app-hpa-v2
...
  "http_requests" on pods:  275m / 500m
Min replicas:               3
Max replicas:               6
Conditions:
  Type            Status  Reason              Message
  ----            ------  ------              -------
  AbleToScale     True    SucceededRescale    the HPA controller was able to update the target scale to 3
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from pods metric http_requests
  ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  SuccessfulRescale  5m    horizontal-pod-autoscaler  New size: 4; reason: pods metric http_requests above target
  Normal  SuccessfulRescale  13s   horizontal-pod-autoscaler  New size: 3; reason: All metrics below target
```

and the HPA terminates one of the pods to bring them back to the default count of 3:

```bash
$ kubectl get pods -l app=go-app
NAME                                 READY     STATUS    RESTARTS   AGE
go-app-deployment-7f8d8bcbbc-dgqrz   1/1       Running   0          1h
go-app-deployment-7f8d8bcbbc-dszdw   1/1       Running   0          1h
go-app-deployment-7f8d8bcbbc-z8kb2   1/1       Running   0          1h
```

## Next Steps

The next step naturally would be exploring autoscaling based on multiple metrics, maybe something like this:

```yaml
# go-app-hpa-v2.yml
---
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: go-app
spec:
  scaleTargetRef:
    # point the HPA at the sample application
    # you created above
    #apiVersion: apps/v1
    apiVersion: extensions/v1beta1
    kind: Deployment
    name: go-app-deployment
  minReplicas: 3
  maxReplicas: 6
  metrics:
  # use a "Pods" metric, which takes the average of the
  # given metric across all pods controlled by the autoscaling target
  - type: Pods
    pods:
      # use the metric that you used above: pods/http_requests
      metricName: http_requests
      # target 500 milli-requests per second,
      # which is 1 request every two seconds
      targetAverageValue: 500m
  - type: Resource
    resource:
      name: cpu
      targetAverageUtilization: 80
  - type: Pods
    pods:
      metricName: memory
      targetAverageValue: 100Mi
```

combining the `http_requests` rate with CPU utilization (80% threshold) or Memory utilization (100MB threshold) limits or even both.

## References

* <https://github.com/kubernetes/kops/blob/master/addons/metrics-server/README.md>
* <https://github.com/kubernetes/kops/blob/master/docs/horizontal_pod_autoscaling.md>
* <https://github.com/DirectXMan12/k8s-prometheus-adapter/blob/master/docs/config.md>
* <https://github.com/DirectXMan12/k8s-prometheus-adapter/blob/master/docs/sample-config.yaml>
* <https://github.com/DirectXMan12/k8s-prometheus-adapter/blob/master/docs/config-walkthrough.md>
* <https://github.com/DirectXMan12/k8s-prometheus-adapter/blob/master/docs/walkthrough.md>
* <https://github.com/DirectXMan12/k8s-prometheus-adapter/blob/master/deploy/manifests/custom-metrics-config-map.yaml>