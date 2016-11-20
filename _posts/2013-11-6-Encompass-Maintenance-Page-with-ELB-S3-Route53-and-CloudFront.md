---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Setting up Encompass Maintenance Page with ELB, S3, Route53 and CloudFront'
categories: 
  - High-Availability
tags: [aws, cdn, cloudfront, s3]
date: 2015-4-21
---

This is for the environments we have `ELB (Elastic Load Balancer)` instead of `HAProxy`. The idea is to host the maintenance page as static website in `S3` bucket and then have a `Failover` DNS records in `Route53` for the targeted subdomain. To enable SSL support, the S3 bucket is going to be accessed via `CloudFront` CDN distribution where we upload our SSL certificate. The ELB will be set as `Primary` Record with target health evaluation via Route53 DNS health check and the CDN as `Secondary`. In this way the traffic will always flow through the ELB except when it's backends become unresponsive in which case the DNS record will switch to the CDN/S3 bucket and our static Maintenance Page will get served.

## Configuration

### S3 Bucket

* Create S3 bucket with **EXACTLY** the same name as the domain/subdomain we want to create static page for, ie `example.encompasshost.com`
* Enable the Static Website Hosting option on the bucket and set the Index Document field to index.html
* In the Permissions section, add new bucket permission for `Everyone` and tick the only the `View Permissions` check-box
* In the same section, click on `Add Policy` button and create new `Bucket Policy` to make the bucket public by pasting the following content in the policy field

  ```json
  {
    "Version":"2012-10-17",
    "Statement":[
      {
        "Sid":"AddPerm",
        "Effect":"Allow",
        "Principal": "*",
        "Action":["s3:GetObject"],
        "Resource":["arn:aws:s3:::example.encompasshost.com/*"]
      }
    ]
  }
  ```

  The Resource should be appropriately set to match our bucket name.
* Enter the bucket and create the folders needed and upload the maintenance page, the fonts and images
* Since we are going to use CDN to serve our S3 maintenance page, we include the following caching headers in our `index.html` page
  
  ```html  
  <meta http-equiv="Cache-Control" content="public,max-age=900,must-revalidate" />
  <meta http-equiv="ETag" content="201504211145" />
  <meta http-equiv="Vary" content="Accept-Encoding,ETag" />
  <meta http-equiv="Pragma" content="public,max-age=604800,must-revalidate" /> 
  ```

  The `ETag` field is important to refresh the page when we change it's content or the old cached one will keep being served to the clients from the CDN cache. The format I chose is `YYYYMMDDHHmm` and should be good enough to support even multiple page versions per day (on each change we need to change the Etag timestamp). The page and its assets will be cached for 15 minutes.

* To index our maintenance page we upload `robots.txt` file to the bucket
  
  ```
  robots.txt
  User-agent: *
  Disallow: /font/
  Disallow: /img/
  ```

### CloudFront

To use our Encompasshost certificate in CDN we need to upload it first to our IAM service:

```
ubuntu@server:~/ssl_encompasshost$ aws iam upload-server-certificate
--server-certificate-name EncompasshostWildcardCert --certificate-body file://encompasshost-crt.pem --private-key file://encompasshost-key.pem --certificate-chain file://encompasshost-cachain.pem --path /cloudfront/star-encompasshost-com/
{
    "ServerCertificateMetadata": {
        "Path": "/cloudfront/star-encompasshost-com/",
        "Arn": "arn:aws:iam::<my-arn>:server-certificate/cloudfront/star-encompasshost-com/EncompasshostWildcardCert",
        "ServerCertificateId": "AS...V6",
        "ServerCertificateName": "EncompasshostWildcardCert",
        "UploadDate": "2015-04-21T06:39:35.414Z"
    }
}
```

Then we go on to creating a new distribution. When finished and deployed it should have the following parameters:

```
Distribution ID: E2...1M
Log Prefix: -
Delivery Method: Web
Cookie Logging: Off
Distribution Status: Deployed
Comment: -
Price Class: Use All Edge Locations (Best Performance)
State: Enabled
Alternate Domain Names (CNAMEs): example.encompasshost.com
SSL Certificate: EncompasshostWildcardCert
Domain Name: dy...sl.cloudfront.net
Custom SSL Client Support: Only Clients that Support Server Name Indication (SNI)
Default Root Object: index.html
Last Modified: 2015-04-21 17:19 UTC+10
Log Bucket: -
```

### Route 53

We move now to setting up our DNS fail over strategy. First we create Route53 Health Check pointing to the ELB serving our site. When finished it should have the following parameters:

```
Name: EXAMPLE
URL: https://dualstack.example-elasticl-....eu-west-1.elb.amazonaws.com:443/resource/hc/application
Host Name: dualstack.example-elasticl-....eu-west-1.elb.amazonaws.com
IP Address: -
Protocol: HTTPS
Port: 443
Request Interval: 10 seconds
Failure Threshold: 2
```

The URL and Host Name should be pointing to our ELB's CNAME (or A record as named on the ELB's page). In less then a minute the `Healt Check` should show as Healthy in the heath checks table in Route53. While we are here, we also create an CloudWatch Alarm so we get emails when the site is down and switch over to the Maintenance Page should happen.

Now we need to edit the existing Route53 Record Set for the domain name, in our case `example.encompasshost.com` (or create a new one if it doesn't exist yet). We need to convert this record into `Failover` type. When finished the record should have the following parameters:

```
Name: example.encompasshost.com.
Type: A - IPv4 address
Alias: Yes
Alias Target: <select our ELB from the drop-down menu>
Alias Hosted Zone ID: Z3...W2
Routing Policy: Failover
Failover Record Type: Primary
Set ID: example-Primary
Evaluate Target Health: Yes
Associate with Health Check: Yes
```

When choosing Yes for the Associate with Health Check option, a drop-down menu will appear from which we can select our newly created EXAMPLE Health Check.

Next we create another `Failover Record` for the same domain name with the S3 bucket, actually the CDN distribution we use the S3 bucket as source, as target and set it as `Secondary`. The parameters we need to set:

```
Name: example.encompasshost.com.
Type: A - IPv4 address
Alias: Yes
Alias Target: <our CLoudFront distribution will appear in the drop-down menu and we select it>
Routing Policy: Failover
Failover Record Type: Secondary
Set ID: example-Secondary
Evaluate Target Health: No
Associate with Health Check: No
```

This will work for most of the modern browsers with SNI support (IE7+ on Windows Vista or higher, FF2+, Opera8+, Chrome6+, Safari3+). For various browser support refer to the following page: [Server Name Indication](http://en.wikipedia.org/wiki/Server_Name_Indication#Web_browsers.5B6.5D)
