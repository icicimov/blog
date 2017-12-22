---
type: posts
header:
  teaser: 'kubernetes-logo.png'
title: 'Kubernetes RBAC Authorization and LDAP Authentication with Tokens using API Webhook and kube-ldap-authn'
categories: 
  - Virtualization
tags: [kubernetes, rbac, ldap, kops]
date: 2017-12-1
---

I've been looking for unified authentication solution that will work across all our Kubernetes cluster. Most specifically a solution that would utilize our existing OpenLDAP server and came across [torchbox's Kubernetes LDAP authentication](https://github.com/torchbox/kube-ldap-authn). Looked like exactly what I've been looking for so decided to give it a go.

## LDAP Setup

According to the project documentation we have the following schema:

```
# kubernetesToken.schema
attributeType ( 1.3.6.1.4.1.18171.2.1.8
        NAME 'kubernetesToken'
        DESC 'Kubernetes authentication token'
        EQUALITY caseExactIA5Match
        SUBSTR caseExactIA5SubstringsMatch
        SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 SINGLE-VALUE )

objectClass ( 1.3.6.1.4.1.18171.2.3
        NAME 'kubernetesAuthenticationObject'
        DESC 'Object that may authenticate to a Kubernetes cluster'
        AUXILIARY
        MUST kubernetesToken )
```
already prepared for us that we can use to add new Kubernetes token schema object to LDAP:

```
user@ldap-server:~$ mkdir kubernetes_tokens
user@ldap-server:~$ echo "include /home/user/kubernetesToken.schema" > kubernetes_tokens/schema_convert.conf
user@ldap-server:~$ slaptest -f ~/kubernetes_tokens/schema_convert.conf -F ~/kubernetes_tokens
config file testing succeeded

user@ldap-server:~$ cd kubernetes_tokens/cn\=config/cn\=schema/
```

Modify the schema by removing the bottom lines and `{0}` from the `dn` and `cn` and setting their correct values so we end up with a file like this:

```
user@ldap-server:~/kubernetes_tokens/cn=config/cn=schema$ cat cn\=\{0\}kubernetestoken.ldif 
# AUTO-GENERATED FILE - DO NOT EDIT!! Use ldapmodify.
# CRC32 01065bb4
dn: cn=kubernetestoken,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: kubernetestoken
olcAttributeTypes: {0}( 1.3.6.1.4.1.18171.2.1.8 NAME 'kubernetesToken' DESC 'K
 ubernetes authentication token' EQUALITY caseExactIA5Match SUBSTR caseExactIA
 5SubstringsMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.26 SINGLE-VALUE )
olcObjectClasses: {0}( 1.3.6.1.4.1.18171.2.3 NAME 'kubernetesAuthenticationObj
 ect' DESC 'Object that may authenticate to a Kubernetes cluster' AUXILIARY MU
 ST kubernetesToken )
```

Now we apply the new schema:

```
user@ldap-server:~/kubernetes_tokens/cn=config/cn=schema$ sudo ldapadd -c -Y EXTERNAL -H ldapi:/// -f cn\=\{0\}kubernetestoken.ldif 
adding new entry "cn=kubernetestoken,cn=schema,cn=config"
```

and now we have:

```
user@ldap-server:~$ ldapsearch -x -H ldap:/// -LLL -D "cn=admin,cn=config" -W -b "cn=schema,cn=config" "(objectClass=olcSchemaConfig)" dn -Z
Enter LDAP Password: 
dn: cn=schema,cn=config
dn: cn={0}core,cn=schema,cn=config
dn: cn={1}cosine,cn=schema,cn=config
dn: cn={2}nis,cn=schema,cn=config
dn: cn={3}inetorgperson,cn=schema,cn=config
dn: cn={4}openssh-openldap,cn=schema,cn=config
dn: cn={5}sudo-openldap,cn=schema,cn=config
dn: cn={6}kubernetestoken,cn=schema,cn=config
```

and we can see our new `kubernetestoken` schema in there.

To populate the users LDAP accounts with the new token object I dumped the users account `dn` into a `users.txt` file which content looks like this:

```
dn: uid=user1,ou=Users,dc=mydomain,dc=com
dn: uid=user2,ou=Users,dc=mydomain,dc=com
[...]
```

and created the following `create_token_ldif.sh` script:

```
#!/bin/bash

while read -r user; do
fname=$(echo $user | grep -E -o "uid=[a-z0-9]+" | cut -d"=" -f2)
token=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
cat << EOF > "${fname}.ldif"
$user
changetype: modify
add: objectClass
objectclass: kubernetesAuthenticationObject
-
add: kubernetesToken
kubernetesToken: $token
EOF
done < users.txt

exit 0
```

that helped me update the LDAP users with randomly generated 32 characters long token:

```
for i in *.ldif; do ldapmodify -a -H ldapi:/// -f $i -D "cn=my-admin-user,dc=mydomain,dc=com" -W; done
```

## Kubernetes Setup

First clone the `https://github.com/torchbox/kube-ldap-authn.git` repository locally and follow the very good instructions at the plugin's page [https://github.com/torchbox/kube-ldap-authn](https://github.com/torchbox/kube-ldap-authn). For one of my test cluster named k9s I needed the following steps:

Modified the `config.py` settings file inside the `kube-ldap-authn` directory first to match our LDAP:

```
# config.py

# LDAP search to connect to.  You normally want at least two for redundancy.
LDAP_URL='ldap://ldap-master.mydomain.com/ ldap://ldap-slave.mydomain.com'

# If True, use STARTTLS to connect to the LDAP server.  You can disable this
# if you're using ldaps:// URLs.
LDAP_START_TLS = True

# DN to bind to the directory as before searching.  Required.
LDAP_BIND_DN = 'cn=bind-user,ou=Users,dc=mydomain,dc=com'

# Password to bind as.  Required.
LDAP_BIND_PASSWORD = 'bind-user-password'

# Attribute of the user entry that contains their username.
LDAP_USER_NAME_ATTRIBUTE = 'uid'

# Attribute of the user entry that contains their user id.  Kubernetes describes
# this as "a string which identifies the end user and attempts to be more
# consistent and unique than username".  If your users are posixAccounts,
# uidNumber is a reasonable choice for this.
LDAP_USER_UID_ATTRIBUTE = 'uidNumber'

# Base DN to search for users in.
LDAP_USER_SEARCH_BASE = 'ou=Users,dc=mydomain,dc=com'

# Filter to search for users.  The string {token} is replaced with the token
# used to authenticate.
LDAP_USER_SEARCH_FILTER = "(&(accountStatus=active)(kubernetesToken={token}))"

# Attribute of the group entry that contains the group name.
LDAP_GROUP_NAME_ATTRIBUTE = 'cn'

# Base DN to search for groups in.
LDAP_GROUP_SEARCH_BASE = 'ou=Groups,dc=mydomain,dc=com'

# Filter to search for groups.  The string {username} is replaced by the 
# authenticated username and {dn} by the authenticated user's complete DN. This
# example supports both POSIX groups and LDAP groups.
LDAP_GROUP_SEARCH_FILTER = '(|(&(objectClass=posixGroup)(memberUid={username}))(&(member={dn})(objectClass=groupOfNames)))'
```

Store the config in Kubernetes `Secret`:

```
$ kubectl -n kube-system create secret generic ldap-authn-config --from-file=config.py=config.py
```

Create the `DaemonSet` as per the instructions:

```
$ kubectl create --save-config -f daemonset.yaml
```

you can later confirm the DaemonSet pods have been properly created and running:

```
$ kubectl get pods -l app=kube-ldap-authn -n kube-system
NAME                    READY     STATUS    RESTARTS   AGE
kube-ldap-authn-9v7rf   1/1       Running   0          1d
kube-ldap-authn-bvj69   1/1       Running   0          18d
kube-ldap-authn-jzlkh   1/1       Running   0          21d
```

Install the following `webhook-authn` file on each server under `/srv/kubernetes`:

```
# /srv/kubernetes/webhook-authn
clusters:
  - name: ldap-authn
    cluster:
      server: http://localhost:8087/authn
users:
  - name: apiserver
current-context: webhook
contexts:
- context:
    cluster: ldap-authn
    user: apiserver
  name: webhook
```

If using [Kops (Kubernetes Operations)](https://github.com/kubernetes/kops) like I do, utilize the new `fileAssets` feature and add the following to your cluster config YAML:

```
  fileAssets:
  - name: webhook-authn
    # Note if not path is specificied the default path is /srv/kubernetes/assets/<name>
    path: /srv/kubernetes/webhook-authn
    roles: [Master,Node] # a list of roles to apply the asset to, zero defaults to all
    content: |
      clusters:
        - name: ldap-authn
          cluster:
            server: http://localhost:8087/authn
      users:
        - name: apiserver
      current-context: webhook
      contexts:
      - context:
          cluster: ldap-authn
          user: apiserver
        name: webhook
```

The file destination of `/srv/kubernetes` is chosen since Kops mounts that directory in the API service pods by default.

Finally start the API server with the following flags:

```
  --runtime-config=authentication.k8s.io/v1beta1=true
  --authentication-token-webhook-config-file=/srv/kubernetes/webhook-authn
  --authentication-token-webhook-cache-ttl=5m
```

In case of Kops add the following to your cluster config, `kubeAPIServer` section: 

```
  kubeAPIServer: 
    ## Webhook token authn via LDAP ##
    authenticationTokenWebhookConfigFile: /srv/kubernetes/webhook-authn
    authenticationTokenWebhookCacheTtl: "5m0s"
```

and run the usual sequence of update and upgrade for the cluster.

## Testing

First create `Role` and `RoleBinding` for a `read-only` Role in the cluster. The following manifest creates read-only Role and binds the `myorg-users` LDAP Group to it [encompass-ns-readonly-role-and-binding.yml]({{ site.baseurl }}/download/encompass-ns-readonly-role-and-binding.yml).

```
$ kubectl create --save-config -f encompass-ns-readonly-role-and-binding.yml
```

Now every user we bind with this Role will gain read-only permissions to the encompass `NameSpace` in the cluster.

Next lets create a new user for the k9s cluster that will have the LDAP token for Authentication set:

```
$ kubectl config set-credentials userTest --kubeconfig=/home/igorc/.kube/k9s.virtual.local/config \
  --token=<user-token-from-ldap-account>
$ kubectl config set-context userTest-context --kubeconfig=/home/igorc/.kube/k9s.virtual.local/config \
  --cluster=k9s.virtual.local --namespace=encompass --user=userTest
```

That will add the new user and context to my `Kubeconfig` file for the k9s cluster:

```
apiVersion: v1
clusters:
- cluster:
    certificate-authority: /home/igorc/k9s-ansible/files/ssl/k9s.virtual.local/ca/ca.pem
    server: https://k9s-api.virtual.local
  name: k9s.virtual.local
contexts:
[...]
- context:
    cluster: k9s.virtual.local
    namespace: encompass
    user: userTest
  name: userTest-context
current-context: admin-context
kind: Config
preferences: {}
users:
[...]
- name: userTest
  user:
    as-user-extra: {}
    token: <user-token-from-ldap-account>
```

If we now try running command with this users credentials:

```
$ export KUBECONFIG=/home/igorc/.kube/k9s.virtual.local/config
$ kubectl --context=userTest-context get pods
NAME                       READY     STATUS             RESTARTS   AGE
busybox-6944bc9f7b-kwr8f   1/1       Running            1          3d
busybox2-b6547cbdd-9mvvf   1/1       Running            2          3d
```

we can see it works for the `encompass` NameSpace. 

Now lets try reading a different NameSpace or creating a Pod in the encompass NameSpace:

```
$ kubectl --context=userTest-context get pods -n default
Error from server (Forbidden): pods is forbidden: User "userTest" cannot list pods in the namespace "default": No policy matched.

$ kubectl --context=userTest-context run --image busybox busybox3
Error from server (Forbidden): deployments.extensions is forbidden: User "userTest" cannot create deployments.extensions in the namespace "encompass": No policy matched.
```

we can see these operations are forbidden which is correct since this user belongs to the myorg-users LDAP group which is mapped to the read-only role for the encompass NameSpace in the cluster via RBAC.
