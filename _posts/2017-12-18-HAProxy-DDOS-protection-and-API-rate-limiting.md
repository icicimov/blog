---
type: posts
header:
  teaser: 'word-image.png'
title: 'HAProxy DDOS protection and API rate limiting'
categories: 
  - DevOps
tags: ['haproxy', 'ddos'] 
date: 2017-12-18
---

HAProxy is great reverse proxy and load balancer but can also be used for DDOS protection and rate limiting with great success. The below configuration provides DOS protection and API calls rate limiting:

```
frontend fe_default
    bind *:80
    bind *:443 ssl crt ...
    mode http

    # Detect an API call
    acl tx_is_api hdr_dom(Host) -i -m sub \-api
    acl tx_is_api path_reg -i ^(/myapp)?/api/.*$
    acl has_auth_header req.fhdr(Authorization) -m found

    # connection, http request and data rate abuses get blocked
    stick-table type ip size 200k expire 30s store gpc0,conn_cur,conn_rate(10s),http_req_rate(10s),bytes_out_rate(30s),http_err_rate(10s)
    acl conn_rate_abuse  sc1_conn_rate gt 20
    acl mark_as_abuser   sc1_inc_gpc0 gt 0
    acl req_rate_abuse   sc1_http_req_rate gt 50
    acl err_rate_abuse   sc1_http_err_rate gt 20
    acl data_rate_abuse  sc1_bytes_out_rate gt 20000000

    # API specific counters
    acl mark_as_api_abuser   sc0_inc_gpc0(be_429_tbl) gt 0
    acl req_rate_api_abuse   sc0_http_req_rate(be_429_tbl) gt 100

    # allow clean known IPs to bypass the filter
    tcp-request connection accept if { src -f /etc/haproxy/whitelist.lst }

    http-request track-sc1 src unless has_auth_header 
    http-request deny if !tx_is_api mark_as_abuser req_rate_abuse or conn_rate_abuse or err_rate_abuse or data_rate_abuse

    # API table fetches
    http-request set-header X-Concat %[req.fhdr(Authorization),word(3,.)]_%[src] if has_auth_header
    http-request track-sc0 req.fhdr(X-Concat),regsub(Bearer\ ,) table be_429_tbl if has_auth_header tx_is_api

    http-request redirect scheme https if !{ ssl_fc }

    # set API call var
    http-request set-var(txn.req_api) bool(true) if tx_is_api

    redirect scheme https if !{ ssl_fc }

    capture request header X-Concat len 50 

    default_backend be_default
    use_backend be_429_slow_down if tx_is_api mark_as_api_abuser req_rate_api_abuse

backend be_429_tbl
    stick-table type string len 180 size 200k expire 30s store gpc0,http_req_rate(10s)

backend be_429_slow_down
    mode http
    timeout tarpit 5s
    http-request tarpit
    reqitarpit .
    errorfile 500 /etc/haproxy/errors/429.http

backend be_default
    acl api_call var(txn.req_api) -m bool
```

Going through the above config we first find some `ACL`s for the purpose of API call detection. Apart from the path method (eg. /api/) and host header (eg. myapp-api.mydomain.com), another way to detect the API calls is via the Authorization header containing Bearer token they all carry. 

We want to rate limit the API calls by tracking them in a separate [stick-table](https://cbonte.github.io/haproxy-dconv/1.7/configuration.html#stick-table) provided by the `be_429_tbl` backend. I also wanted to rate limit the API calls per user and not just a source IP to avoid many users being blocked when they are all behind same IP (NATed connections). The following two lines:

```
http-request set-header X-Concat %[req.fhdr(Authorization),word(3,.)]_%[src] if has_auth_header
http-request track-sc0 req.fhdr(X-Concat),regsub(Bearer\ ,) table be_429_tbl if has_auth_header tx_is_api
```

take care of that where the first one grabs the first two fields (delimited by a dot) of the user's JWT Bearer token and puts them into a header. The second one then concatenates this header's value with the source IP the request is coming from delimited by an underscore thus forming the tracking key for the stick-table. That way from the IP in the stick table we can tell what customer got blocked and we can find more about the particular user by searching in the backend's logs for the first part of the key. Not great but better than nothing. 

In case of rate limit reached we send the offender to the `be_429_slow_down` backend. This backend will slow down the offender via [tarpit timeout](https://cbonte.github.io/haproxy-dconv/1.7/configuration.html#timeout%20tarpit) and send a 429 reply back to inform the user that a limit has been reached and to retry after 5 seconds. 

Finally, the frontend `fe_default` stick-table is used for rate limiting the rest of the calls by connection, request and error rate providing DDOS defense.

This is the `/etc/haproxy/errors/429.http` file containing the 429 reply:

```
HTTP/1.1 429 Too Many Requests
Cache-Control: no-cache
Connection: close
Content-Type: text/plain
Retry-After: 5

Too Many Requests.
```

The content of the response in this file is configurable of course and we can add any additional headers we deem necessary.

To test we can set the rate limit to one `sc0_http_req_rate(be_429_tbl) gt 1`. Then send a request and 5 seconds later we should see the 429 reply:

```
$ curl -ksSNIL -X GET -H "Authorization: Bearer 781292.db7bc3a58fc5f07e.NMl3S1ma52G55imKVFFGB4El0PHPHkvtyW25dKSbysA" https://myapp.mydomain.com/myapp/api/v1/system/build

HTTP/1.1 429 Too Many Requests
Cache-Control: no-cache
Connection: close
Content-Type: text/plain
Retry-After: 10

Too Many Requests.
```

If we run the below command in separate console to watch the `be_429_tbl` stick-table:

```
watch -n2 'echo "show table be_429_tbl" | socat stdio unix-connect:/run/haproxy/admin.sock'
```

we can see the relevant entry for rate limiting by user token and IP merged into a single key delimited by underscore:

```
0x7fdcd978a298: key=781292.db7bc3a58fc5f07e_XXX.XXX.XXX.XXX use=0 exp=9445 gpc0=1 http_req_rate(10000)=1
```

This solution does its job but certainly is not perfect. First there is no easy way to tell which user (from the application perspective) got blocked by just looking at haproxy which makes any kind of reporting difficult. And second the 429 reply is static and lacks the flexibility of dynamically being modified by adding custom headers (eg. timer header showing time left till the block gets removed) on the fly. I'm sure though all this can be overcome by doing this in different way using some LUA scripting.