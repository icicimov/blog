---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'GitLab Server with LDAP and S3 backend'
categories: 
  - Server
tags: ['gitlab', 'ldap', 'CI/CD', 'aws']
date: 2017-5-2
---

This is a procedure that enables S3 as backend storage for a GitLab Image Registry with LDAP for secure access and user authentication.  

# Installation

This is running on Ubuntu-16.04 VM in EC2 AU region.

```
$ sudo apt install curl openssh-server ca-certificates postfix
$ sudo domainname domain.com
$ echo '10.180.18.65 git.domain.com git' | sudo tee -a /etc/hosts
$ curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
$ sudo apt install gitlab-ce
$ sudo gitlab-ctl reconfigure
```

Setup LDAP integration for easy user management in the `/etc/gitlab/gitlab.rb` file:

```
[...]
external_url 'https://git.domain.com'
gitlab_rails['ldap_enabled'] = true
gitlab_rails['ldap_servers'] = YAML.load <<-'EOS' # remember to close this block with 'EOS' below
   main: # 'main' is the GitLab 'provider ID' of this LDAP server
     label: 'LDAP'
     host: 'ldap.domain.com'
     port: 389
     uid: 'uid'
     method: 'tls' # "tls" or "ssl" or "plain"
     bind_dn: 'cn=binduser,ou=Users,dc=domain,dc=com'
     password: 'password'
     active_directory: false
     allow_username_or_email_login: false
     block_auto_created_users: false
     base: 'ou=Users,dc=domain,dc=com'
     user_filter: ''
     attributes:
       username: ['uid', 'userid', 'sAMAccountName']
       email:    ['mail', 'email', 'userPrincipalName']
       name:       'cn'
       first_name: 'givenName'
       last_name:  'sn'
EOS
[...]
```

and reconfigure again:

```
$ sudo gitlab-ctl reconfigure
```

Set the domain certificate for Nginx which we use as frontend:

```
$ sudo mkdir -p /etc/gitlab/ssl
$ sudo vi /etc/gitlab/ssl/git.domain.com.crt
$ sudo vi /etc/gitlab/ssl/git.domain.com.key
$ sudo chmod 0600 /etc/gitlab/ssl/git.domain.com.key
$ sudo gitlab-ctl reconfigure
```

The `/etc/gitlab/ssl/git.domain.com.crt` should have the full certificate chain. Login to https://git.domain.com using LDAP or built in login.

# Enable built-in Docker Image Registry with S3 backend

First we create the S3 bucket:

```
$ aws s3api create-bucket --bucket gitlab-image-registry --region ap-southeast-2 --create-bucket-configuration LocationConstraint=ap-southeast-2
$ aws s3api put-bucket-versioning --region ap-southeast-2 --bucket gitlab-image-registry --versioning-configuration Status=Enabled
```

and add the bucket access rights to an `Instance IAM Role` we assign to the GitLab instance:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": "arn:aws:s3:::gitlab-image-registry"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:ListMultipartUploadParts",
                "s3:AbortMultipartUpload"
            ],
            "Resource": "arn:aws:s3:::gitlab-image-registry/*"
        }
    ]
}
```

Next edit the `Container registry settings` section of the config file as follows:

```
root@git:~# vi /etc/gitlab/gitlab.rb
[...]
###############################
# Container registry settings #
###############################
# see http://docs.gitlab.com/ce/administration/container_registry.html
#
 
registry_external_url 'https://git.domain.com:5001'
 
# Settings used by GitLab application
gitlab_rails['registry_enabled'] = true
gitlab_rails['registry_host'] = "git.domain.com"
gitlab_rails['registry_port'] = "5001"
gitlab_rails['registry_api_url'] = "http://localhost:5000"
gitlab_rails['registry_key_path'] = "/var/opt/gitlab/registry/certificate.key"
gitlab_rails['registry_path'] = "/var/opt/gitlab/gitlab-rails/shared/registry"
gitlab_rails['registry_issuer'] = "omnibus-gitlab-issuer"
 
# Settings used by Registry application
registry['enable'] = true
registry['username'] = "user"
registry['group'] = "encompass"
registry['uid'] = nil
registry['gid'] = nil
registry['dir'] = "/var/opt/gitlab/registry"
registry['log_directory'] = "/var/log/gitlab/registry"
registry['log_level'] = "debug"
registry['rootcertbundle'] = "/var/opt/gitlab/registry/gitlab-registry.crt"
registry['storage_delete_enabled'] = true
# # Registry backend storage, see http://docs.gitlab.com/ce/administration/container_registry.html#container-registry-storage-driver
registry['storage'] = {
   's3' => {
#     'accesskey' => 'AKIAKIAKI',
#     'secretkey' => 'secret123',
     'region' => 'ap-southeast-2',
     'bucket' => 'gitlab-image-registry'
   }
}
[...]
```

Which means GitLab will run internal docker registry on port 5000 accessible to the outside world at `git.domain.com:5001`. Then we reconfigure and restart the GitLab services:

```
root@git:~# gitlab-ctl reconfigure
root@git:~# gitlab-ctl restart
```

After which we can test the login using our LDAP password:

```
ubuntu@ip-172-31-1-215:~$ sudo docker login -u user git.domain.com:5001
Password:
Login Succeeded
```

And start uploading locally created Docker images to the GitLab image repository per project:

```
ubuntu@ip-172-31-1-215:~$ sudo docker push git.domain.com:5001/encompass/images/ubuntu-trusty:latest
ubuntu@ip-172-31-1-215:~$ sudo docker push git.domain.com:5001/encompass/images/kubectl_deployer:latest
ubuntu@ip-172-31-1-215:~$ sudo docker push git.domain.com:5001/encompass/nodejs-app/nodejs-app:latest
```

# CI/CD Pipelines

GitLab comes with integrated CI/CD Pipelines. To enable it we need to install the GitLab Runner.

```
root@git:~# curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-ci-multi-runner/script.deb.sh | bash
root@git:~# apt-get update && apt-get install gitlab-ci-multi-runner
```

then to register a new Runner we can run:

```
root@git:~# gitlab-ci-multi-runner register
```

to set the parameters interactively, or supply them all on the command line, for example:

```
root@git:~# gitlab-ci-multi-runner register -n \
   --url "https://git.domain.com/ci" \
   --registration-token "_i6unzULiAdf8SZJ6PRx" \
   --executor docker \
   --description "Docker-in-Docker Runner" \
   --docker-image "docker:latest" \
   --volumes ["/root/.kube-config:/kube-config:ro"]
   --docker-privileged
Running in system-mode.                                                          
Registering runner... succeeded                     runner=_i6unzUL
Runner registered successfully. Feel free to start it, but if it's running already the config should be automatically reloaded!
```

We can also make additional changes in the GitLab Runner process configuration file `/etc/gitlab-runner/config.toml`, see [Advanced configuration](https://gitlab.com/gitlab-org/gitlab-ci-multi-runner/blob/master/docs/configuration/advanced-configuration.md) for details.

Each project generates its own registration token that we give it to the runner creation command as shown above so the runner becomes specific for that project only. For global runners we need to supply the registration token for the GitLab server which only the admin account has access to.