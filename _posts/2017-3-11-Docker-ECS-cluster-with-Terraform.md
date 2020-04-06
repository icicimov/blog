---
type: posts
header:
  teaser: 'aws-ecs.jpeg'
title: 'Docker ECS cluster with Terraform'
categories: 
  - Docker
tags: ['docker', 'containers', 'ecs', 'aws', 'terraform']
date: 2017-03-11
---

# Introduction

The intention of this exercise is to deploy and test any future Encompass micro-services based on Docker in Amazon ECS. It will provide the skeleton for the AWS infrastructure we need to build for this purpose and with some small changes it can be utilized as it is. The basic motivation behind setting our micro-services inside Docker is the portability provided by containers, meaning the same container can run in production or locally on the developer's machine without any modifications.

Before we start, we need to get familiar with the following AWS terms:

* ECS Instance Cluster - Cluster of EC2 instances the containers will be running on
* ECS Service - Logical group of containers running the same micro service(s)
* ECS Task - Container micro service (application) definition
* ALB - Application Load Balancer, makes routing decisions at the application layer (HTTP/HTTPS), supports path-based routing, and can route requests to one or more ports on each container instance in our cluster. It also supports dynamic host port mapping, meaning we can run multiple instances of the same container on different host ephemeral ports, and HTTP/2 support is already included.

The image below is a good representation of the infrastructure we are building.

![ECS Infrastructure](/blog/images/ecs_concept_diagram.jpg "ECS Infrastructure")

The set-up will provide the following features:

* Creates ECS instances cluster in existing VPC based on the latest official Amazon ECS AMI (docker 1.12 support)
* Creates IAM security roles and policies to enable access to CloudWatch, ECS, ECR and Autoscaling services for the ECS container instances
* Creates ECS task and service for an example micro service application (nodejs-app)
* The resulting service is only accessible internally, meaning it is only avaible to other services inside the VPC
* Provides service level load balancing via ALB (single access point for the service)
* Provides Auto-scaling on ECS instances cluster and ECS service level (cpu and memory based)
* Provides fault-tolerance and self-healing; failed ECS cluster instance will be removed from it's Autoscaling group and new one launched to replace it
* Provides container instance fault-tolerance and self-healing; the ecs-agent installed on each EC2 instance monitors the health of the containers and restarts the ones that error or crash
* Provides rolling service updates with guarantee that at least 50% of the instances will always be available during the process
* Creates (via user-data and cloud-init) separate Consul client container on each ECS cluster instance that registers the instance with the existing Consul cluster in the VPC
* Creates (via user-data and cloud-init) separate Registrator container on each ECS cluster instance that registers each service with the existing Consul cluster in the VPC
* Collects ECS cluster instance metrics about CPU and RAM and sends them to AWS CloudWatch
* Collects logs from the running application container(s) and sends them to AWS CloudWatch Logs
* Sends SNS email notifications to nominated recipient(s) on scale-up/scale-down events

The execution part:

* I have created a simple NodeJS application which I have uploaded to Docker hub repository under `igoratencompass/nodejs-app`. This is where the ECS will fetch the docker image from to create its task and service. Using Amazon ECR (Elastic Container Registry) might also be considered for storing the docker images, the IAM role the ECS instances are being launched with caters for this option too
* I have used Terraform as infrastructure orchestration tool. The source code can be found at https://git.encompasshost.com/igor.cicimov/ecs-cluster

# Setup

The example ECS cluster will be built and deployed on 2 x t2.micro instances (to reduce costs as much as possible) in the ECSTEST VPC.

## Prepare a sample app

The first step would be creating the micro-service application packaged into Docker container. For this POC scenario I have made the following assumptions regarding the application (the micro-service):

* The service only needs to return the container id it is running on so we can see it is working across different containers and ECS cluster instances
* The service needs to provide a separate health check access point to be used by load balancer
* The service needs to be only internally accessible ie used by other services running in the same VPC where it is being deployed
* The service is stateless meaning dos not contain any locally stored data
* The service (for now) does not need to interact with other service(s), for example db back-end or JMS

The `/app` directory in the repository contains the files needed to build the app. It's a simple NodeJS app as shown below:

```js
//app.js
var http = require('http');
var os = require('os');

//var port = process.argv[2];
var port = 8080;

var server = http.createServer(function (req, res) {
  if (req.url === "/") {
    res.writeHead(200, {'Content-Type': 'text/plain'});
    res.end('I am: ' + os.hostname() + '\n');
  }
  else if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "text/html" });
    res.end("Service status: RUNNING\n");
  }
  else {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("404 error! Page not found\n");
  }
}).listen(port);
console.log('Server running at http://127.0.0.1:' + port);
```

that will return the container id it is running on, status code 200 for the `/health` URI (used later for service health checks) and 404 for anything else. Then we create `package.json` file to tell npm how to deploy it:

```json
{
  "name": "nodejs-app",
  "version": "1.0.0",
  "description": "Node.js on Docker",
  "author": "Igor Cicimov <igorc@encompasscorporation.com.com>",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {
    "express": "^4.13.3"
  }
}
```

Now on to Docker setup. We create a Dockerfile in the same directory, the below container is based on Alpine Linux 3.2:

```
FROM node:alpine

# Create app directory
WORKDIR /usr/src/app

# Install app dependencies
COPY package.json /usr/src/app/
RUN npm install --production

# Bundle app source
COPY . /usr/src/app

# Run as non root user
RUN addgroup -g 10001 -S app && \
    adduser -u 10001 -S app -G app 
USER app

EXPOSE 8080
#ENTRYPOINT ["node", "app.js", "8080"]
CMD [ "npm", "start" ]
```

If we need/want to base our containers on Ubuntu image I would recommend the baseimage-docker version from Phusion ( see https://github.com/phusion/baseimage-docker for details). And finally a `.dockerignore` file to remove the nodejs build directories at the end:

```
node_modules
npm-debug.log
```

We end up with something like this:

```bash
ubuntu@ip-172-31-1-215:~/ecs/app$ tree -a .
.
├── app.js
├── Dockerfile
├── .dockerignore
└── package.json
 
0 directories, 4 files
```

Now we need to locally build the container, push the image to our DockerHub repository and test our app:

```bash
ubuntu@ip-172-31-1-215:~/ecs/app$ sudo docker build -t igoratencompass/nodejs-app .
ubuntu@ip-172-31-1-215:~/ecs/app$ sudo docker push igoratencompass/nodejs-app
ubuntu@ip-172-31-1-215:~/ecs/app$ sudo docker run -d --name="nodejs-app" -p 8080:8080 -t -i igoratencompass/nodejs-app
 
ubuntu@ip-172-31-1-215:~/ecs/app$ sudo docker ps
CONTAINER ID        IMAGE                        COMMAND             CREATED             STATUS              PORTS                    NAMES
a56200c8e17f        igoratencompass/nodejs-app   "npm start"         11 seconds ago      Up 10 seconds       0.0.0.0:8080->8080/tcp   nodejs-app
 
ubuntu@ip-172-31-1-215:~/ecs/app$ curl -i localhost:8080
HTTP/1.1 200 OK
Content-Type: text/plain
Date: Mon, 06 Mar 2017 01:57:27 GMT
Connection: keep-alive
Transfer-Encoding: chunked
 
I am: a56200c8e17f
 
ubuntu@ip-172-31-1-215:~/ecs/app$ curl -i localhost:8080/health
HTTP/1.1 200 OK
Content-Type: text/html
Date: Mon, 06 Mar 2017 01:57:46 GMT
Connection: keep-alive
Transfer-Encoding: chunked
 
Service status: RUNNING
 
ubuntu@ip-172-31-1-215:~/ecs/app$ curl -i localhost:8080/anythingelse
HTTP/1.1 404 Not Found
Content-Type: text/plain
Date: Mon, 06 Mar 2017 01:58:03 GMT
Connection: keep-alive
Transfer-Encoding: chunked
 
404 error! Page not found
ubuntu@ip-172-31-1-215:~/ecs/app$
```

## Create the infrastructure

The repository is available at [terraform-consul-ecs-cluster](https://github.com/icicimov/terraform-consul-ecs-cluster). The instructions about running Terraform are in the repository's README file. It basically boils down to:

```bash
$ terraform plan -var-file ecs-cluster.tfvars -var-file provider-credentials.tfvars -out ecs.tfplan
$ terraform apply -var-file ecs-cluster.tfvars -var-file provider-credentials.tfvars ecs.tfplan
```

Terraform outputs some useful data on every step of the execution and at the end we will get the info from our play output:

```
[... Lots of other output here ...]
 
Outputs:
 
autoscaling_notification_sns_topic = arn:aws:sns:eu-west-1:XXXXXXXXXXXX:ecstest-ecs-sns-topic
nodejs-app_frontend_url = http://internal-ECSTEST-ecs-nodejs-app-alb-13xxxxxxxx.eu-west-1.elb.amazonaws.com
```

where we can see the URL of the ECS container app we just deployed. Now if we test the URL from any instance inside ECSTEST VPC:

```
root@ip-10-22-2-84:~# for i in `seq 1 7`; do curl http://internal-ECSTEST-ecs-nodejs-app-alb-13xxxxxxxx.eu-west-1.elb.amazonaws.com; done
I am: eb0bc76f8658
I am: eb0bc76f8658
I am: 32f417bdd0ed
I am: 32f417bdd0ed
I am: eb0bc76f8658
I am: eb0bc76f8658
I am: 32f417bdd0ed
```

we can see the requests being load balanced by the ALB across both container apps although each of them has been deployed on separate ECS host instance. We login to both ECS nodes to check the status:

```bash
[root@ip-10-22-4-83 ~]# docker ps
CONTAINER ID        IMAGE                               COMMAND                  CREATED             STATUS              PORTS                                                                                                                                                      NAMES
faf9ab00c466        gliderlabs/registrator:latest       "/bin/registrator -ip"   57 minutes ago      Up 57 minutes                                                                                                                                                                  consul-registrator
3e4da56397ed        progrium/consul                     "/bin/start -advertis"   57 minutes ago      Up 57 minutes       53/tcp, 0.0.0.0:53->53/udp, 8300/tcp, 0.0.0.0:8301->8301/tcp, 0.0.0.0:8400->8400/tcp, 8302/tcp, 0.0.0.0:8301->8301/udp, 0.0.0.0:8500->8500/tcp, 8302/udp   consul-agent
32f417bdd0ed        igoratencompass/nodejs-app:latest   "npm start"              56 minutes ago      Up 56 minutes       0.0.0.0:8080->8080/tcp                                                                                                                                     ecs-nodejs-app-2-nodejs-app-f091d4ef96d3f0971a00
d21c0e24f7a8        amazon/amazon-ecs-agent:latest      "/agent"                 About an hour ago   Up About an hour                                                                                                                                                               ecs-agent
[root@ip-10-22-3-60 ~]# docker ps
CONTAINER ID        IMAGE                               COMMAND                  CREATED             STATUS              PORTS                                                                                                                                                      NAMES
d34cb04d0b8b        gliderlabs/registrator:latest       "/bin/registrator -ip"   58 minutes ago      Up 58 minutes                                                                                                                                                                  consul-registrator
3004fc589234        progrium/consul                     "/bin/start -advertis"   58 minutes ago      Up 58 minutes       53/tcp, 0.0.0.0:53->53/udp, 8300/tcp, 0.0.0.0:8301->8301/tcp, 0.0.0.0:8400->8400/tcp, 8302/tcp, 0.0.0.0:8301->8301/udp, 0.0.0.0:8500->8500/tcp, 8302/udp   consul-agent
eb0bc76f8658        igoratencompass/nodejs-app:latest   "npm start"              57 minutes ago      Up 57 minutes       0.0.0.0:8080->8080/tcp                                                                                                                                     ecs-nodejs-app-2-nodejs-app-80a2cb879ea2a6ba0300
238c51a917bd        amazon/amazon-ecs-agent:latest      "/agent"                 About an hour ago   Up About an hour
```

and we can see 4 containers running on each of them as expected. For the Registrator container we can notice:

```bash
[root@ip-10-22-4-83 ~]# docker logs consul-registrator
[...]
2017/03/07 06:02:15 Using consul adapter: consul://10.22.4.83:8500
2017/03/07 06:02:15 Connecting to backend (0/0)
2017/03/07 06:02:15 consul: current leader  10.22.5.48:8300
2017/03/07 06:02:15 Listening for Docker events ...
2017/03/07 06:02:15 Syncing services on 4 containers
2017/03/07 06:02:15 ignored: faf9ab00c466 no published ports
2017/03/07 06:02:15 added: 3e4da56397ed i-00xxxxxxxxxxxxxxx:consul-agent:8500
2017/03/07 06:02:15 added: 3e4da56397ed i-00xxxxxxxxxxxxxxx:consul-agent:53:udp
2017/03/07 06:02:15 added: 3e4da56397ed i-00xxxxxxxxxxxxxxx:consul-agent:8301
2017/03/07 06:02:15 added: 3e4da56397ed i-00xxxxxxxxxxxxxxx:consul-agent:8301:udp
2017/03/07 06:02:15 ignored: 3e4da56397ed port 8300 not published on host
2017/03/07 06:02:15 ignored: 3e4da56397ed port 8302 not published on host
2017/03/07 06:02:15 added: 3e4da56397ed i-00xxxxxxxxxxxxxxx:consul-agent:8400
2017/03/07 06:02:15 ignored: 3e4da56397ed port 8302 not published on host
2017/03/07 06:02:15 ignored: 3e4da56397ed port 53 not published on host
2017/03/07 06:02:15 added: 32f417bdd0ed i-00xxxxxxxxxxxxxxx:ecs-nodejs-app-2-nodejs-app-f091d4ef96d3f0971a00:8080
2017/03/07 06:02:15 ignored: d21c0e24f7a8 no published ports
```

the instance adding the ECS instance and the nodejs-app app to the Consul cluster. Now if we check from any node in ECSTEST VPC:

```bash
root@ip-10-22-2-84:~# consul members
Node                 Address           Status  Type    Build  Protocol  DC
[...]
i-08xxxxxxxxxxxxxxx  10.22.3.60:8301   alive   client  0.5.2  2         dc-ecstest
i-00xxxxxxxxxxxxxxx  10.22.4.83:8301   alive   client  0.5.2  2         dc-ecstest
[...]
```

we can confirm our two ECS nodes registered as clients to the Consul cluster.Further If we check for services:

```bash
root@ip-10-22-2-84:~# curl -s localhost:8500/v1/catalog/services | jq -r .
{
  "web": [
    "nginx",
    "ecstest"
  ],
  "tomcat": [
    "tomcat",
    "ecstest"
  ],
  "nodejs-app": [],
  "haproxy": [
    "haproxy",
    "ecstest"
  ],
[...]
```

we can see a new nodejs-app service has been added too, and if we check it out:

```bash
root@ip-10-22-2-84:~# curl -s localhost:8500/v1/catalog/service/nodejs-app?pretty
[
    {
        "Node": "i-00xxxxxxxxxxxxxxx",
        "Address": "10.22.4.83",
        "ServiceID": "i-00xxxxxxxxxxxxxxx:ecs-nodejs-app-2-nodejs-app-f091d4ef96d3f0971a00:8080",
        "ServiceName": "nodejs-app",
        "ServiceTags": [],
        "ServiceAddress": "10.22.4.83",
        "ServicePort": 8080
    },
    {
        "Node": "i-08xxxxxxxxxxxxxxx",
        "Address": "10.22.3.60",
        "ServiceID": "i-08xxxxxxxxxxxxxxx:ecs-nodejs-app-2-nodejs-app-80a2cb879ea2a6ba0300:8080",
        "ServiceName": "nodejs-app",
        "ServiceTags": [],
        "ServiceAddress": "10.22.3.60",
        "ServicePort": 8080
    }
]
```

we can find all the details including the service address and service port. We can also use the DNS API to get the service address too:

```bash
root@ip-10-22-2-84:~# dig +short @127.0.0.1 -p 8600 nodejs-app.service.consul
10.22.3.60
10.22.4.83
```

and via the SRV record we can get it's port which is 8080 in this case:

```bash
root@ip-10-22-2-84:~# dig +short @127.0.0.1 -p 8600 nodejs-app.service.consul -t SRV
1 1 8080 i-08xxxxxxxxxxxxxxx.node.dc-ecstest.consul.
1 1 8080 i-00xxxxxxxxxxxxxxx.node.dc-ecstest.consul.
```

This means our other services can reference this service in many different ways starting by it's ALB URL `http://internal-ECSTEST-ecs-nodejs-app-alb-13xxxxxxxx.eu-west-1.elb.amazonaws.com`, by querying the service API point `localhost:8500/v1/catalog/service/nodejs-app` or simply via DNS query for the `nodejs-app.service.consul` service name.

## Deployments

After the initial cluster set-up and service deployment we would like to be able to deploy new versions in the future. With Terraform that is very simple. The application parameters are set-up in a Terraform variable where things like image and image version are specified:

```
app = {
[...]
    image                 = "igoratencompass/nodejs-app"
    version               = "latest"
[...]
}
```
To deploy new version of the application/service all we need to do is upload our new image with some distinctive tag, for example `igoratencompass/nodejs-app:v2` in our DockerHub repository and re-run Terraform with the new value of the version parameter. Note that we don't even have to change the value in the config file we can supply it on the fly on the command line:

```bash
$ terraform apply -var app.version="v2"
```

and that's all, Terraform will calculate and make all the changes needed ie change the image version of the ECS task which will in turn trigger a rolling deployment to the new version. If we want to check first all the changes Terraform will make we can run:

```bash
$ terraform plan -var app.version="v2"
```

and review the output before we apply.
