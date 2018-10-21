---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Hosting static Website with S3 bucket and CloudFront CDN'
categories: 
  - Server
tags: ['aws', 'cdn']
date: 2016-10-31
---

Amazon AWS offers convenient way for hosting static website via S3 bucket providing CDN caching and SSL encryption using `CloudFront`.

## S3 bucket

First we need to create S3 Bucket for the files and bucket access policy for public read access. Create the `policy.json` file with following content:


```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::my-bucket/*"
        }
    ]
}
```

We also enable the Static website hosting feature on the bucket, select `Enable website hosting` and set `index.html` in the `Index document` field. If we create the following `website.json` file:

```json
{
  "IndexDocument": {
      "Suffix": "index.html"
  }
}
```

and put the above policy into `policy.json` file then we can do all this from the command line using AWS CLI tools:

```bash
$ aws s3api create-bucket --bucket my-bucket --region eu-west-1 \
--create-bucket-configuration LocationConstraint=eu-west-1
$ aws s3api put-bucket-policy --region eu-west-1 --bucket my-bucket \
--policy file://policy.json
$ aws s3api put-bucket-website --region eu-west-1 --bucket my-bucket \
--website-configuration file://website.json
$ aws s3api put-bucket-versioning --region eu-west-1 --bucket my-bucket \
--versioning-configuration Status=Enabled
$ aws s3 ls
```

We also enable versioning on the S3 bucket so we can roll back if necessary.

## CloudFront CDN

Next is the CloudFront CDN setup. For the `General Section` first:

```
Distribution ID: XXXXXXXXXXXXXX
ARN: arn:aws:cloudfront::xxxxxxxxxxxx:distribution/XXXXXXXXXXXXXX
Log Prefix: -
Delivery Method: Web
Cookie Logging: Off
Distribution Status: Deployed
Comment: -
Price Class: Use All Edge Locations (Best Performance)
AWS WAF Web ACL: -
State: Enabled
Alternate Domain Names (CNAMEs): myapp.mydomain.com
SSL Certificate: <SSL_CERT_ARN>
Domain Name: xxxxxxxxxxxxxx.cloudfront.net
Custom SSL Client Support: Only Clients that Support Server Name Indication (SNI)
Supported HTTP Versions: HTTP/2, HTTP/1.1, HTTP/1.0
IPv6: Disabled
Default Root Object: -
Last Modified: 2016-10-31 13:59 UTC+11
Log Bucket: - 
```

Replace the `<SSL_CERT_ARN>` with a valid certificate ARN already uploaded for the account.

The `Origins Section`:

```
Origin Domain Name: my-bucket.s3-website-eu-west-1.amazonaws.com
Origin Path:
Origin ID: S3-my-bucket/static
Origin Type: Custom Origin
Origin Access Identity: -
Origin Protocol Policy: HTTP Only
HTTPS Port: 443
HTTP Port: 80
```

The `Default Cache Behavior Settings`:

```
Path Pattern: Default (*)
Origin: S3-my-bucket/static   
Viewer Protocol Policy: Redirect HTTP to HTTPS
Allowed HTTP Methods: GET, HEAD   
Cached HTTP Methods: GET, HEAD (Cached by default)

Forward Headers: Whitelist
Whitelist Headers:
3 header(s) whitelisted:
Access-Control-Allow-Origin
Authorization
Origin
 
Object Caching: Use Origin Cache Headers
Minimum TTL: 0   
Maximum TTL: 31536000       
Default TTL: 86400
 
Forward Cookies: None
Query String Forwarding and Caching: None
Smooth Streaming: No
Restrict Viewer Access
(Use Signed URLs or
Signed Cookies): No
Compress Objects Automatically: No
```

The forwarded headers will be needed in case we want to setup CORS on the bucket to tighten up our website security.

## Route53 DNS Record

Create an A ALIAS Record `cdn.mydomain.com` pointing to the domain name of the CloudFront Distribution `xxxxxxxxxxxxxx.cloudfront.net`.

## Application Changes

Edit the app so it loads all assets from `cdn.mydomain.com` and set that URL as default path for all static content.
