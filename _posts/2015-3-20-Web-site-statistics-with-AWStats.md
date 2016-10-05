---
type: posts
title: 'Web site statistics with AWStats'
category: Web Server
tags: [awstats, apache]
---

`Awstats` (Apache Web Statistics) is powerful and highly customizable tool for collecting web site statistics. The purpose of this document is to show one way we are using it for data collection and presentation of heavily customized Apache logs from our company web site.

## Setup

Our Apache access log is heavily customized and the lines look like this:

```
<server-ip>|<loadbalancer-ip>|<client-ip>|AU|17184|-|/var/www/html/media/widgetkit/widgets/mediaplayer/mediaelement/mediaelement-and-player.js|application/javascript|HTTP/1.1|Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/40.0.2214.115 Safari/537.36|http://www.mydomain.com/our-team|GET|80|16912|?_=1425797290939|200|20150308064748|17857|/media/widgetkit/widgets/mediaplayer/mediaelement/mediaelement-and-player.js|www.mydomain.com
```

As reach of information as this is, it is very difficult to process and we need to do some pre-processing before we feed this into Awstats. We start with installing the tool on both servers:

```
$ sudo aptitude install awstats
```

Then, for the reason mentioned before, we are going to parse the logs and convert them in more useful format that Awstats can understand. After looking at the Awstats documentation I have come up with the following filter:

```
awk -F \| 'BEGIN{OFS="|"} {if($3 ~ ",") {split($3,a,", "); $3=a[1]} else $3=$3; print $3,$4,$5,"["$10"]",$11,$12,$16,$17,$18,$19,$20}' | sed -e 's/\(.*\)\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)|/\1\2-\3-\4 \5:\6:\7|/'
```

This will convert the log lines from the above format into this:

```
<client-ip>|AU|17184|[Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/40.0.2214.115 Safari/537.36]|http://www.mydomain.com/our-team|GET|200|2015-03-08 06:47:48|17857|/media/widgetkit/widgets/mediaplayer/mediaelement/mediaelement-and-player.js|www.mydomain.com
```

So first from 20 fields we go down to 11 by keeping only the ones we are interested in and also convert the custom UNIX format time stamp into `%time2`, one of the supported Awstats formats by default. Now all is left is to tell Awstats where to find the result reformatted file and the format the lines are going to have, so we set the following variables in the `/etc/awstats/awstats.conf` file:

```
LogFile="/tmp/awstats.log"
LogType=W
LogFormat="%host %extra1 %bytesd %uabracket %referer %method %code %time2 %extra2 %url %virtualname"
LogSeparator="\|"
SiteDomain="www.mydomain.com"
HostAliases="localhost 127.0.0.1 mydomain.com"
DNSLookup=0
```

letting Awstats know what is our line field separator, domain name and switching off the DNS lookups which will significantly speed up its operation. Now we can run the parser:

```bash
$ cat /var/log/apache2/access.log.1 | awk -F \| 'BEGIN{OFS="|"} {if($3 ~ ",") {split($3,a,", "); $3=a[1]} else $3=$3; print $3,$4,$5,"["$10"]",$11,$12,$16,$17,$18,$19,$20}' | sed -e 's/\(.*\)\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)|/\1\2-\3-\4 \5:\6:\7|/' > /tmp/awstats.log
```

to create the log file we feed into Awstats and and run the parser to update the database for first time and check for any errors:

```bash
$ sudo /usr/bin/awstats -config=www.mydomain.com -update -showdropped -showcorrupted
Create/Update database for config "/etc/awstats/awstats.conf" by AWStats version 7.2 (build 1.992)
From data in log file "/tmp/awstats.log"...
Phase 1 : First bypass old records, searching new record...
Searching new records from beginning of log file...
Phase 2 : Now process new records (Flush history on disk after 20000 hosts)...
Dropped record (method/protocol '-' not qualified when LogType=W): -|-|226|[-]|-|-|400|2015-03-09 06:25:28|64|-|www.mydomain.com
Dropped record (method/protocol 'CONNECT' not qualified when LogType=W): 141.212.121.184|US|0|[-]|-|CONNECT|301|2015-03-14 21:54:19|638534|/index.php|www.mydomain.com
Warning: awstats has detected that some hosts names were already resolved in your logfile /tmp/awstats.log.
If DNS lookup was already made by the logger (web server), you should change your setup DNSLookup=1 into DNSLookup=0 to increase awstats speed.
Jumped lines in file: 0
Parsed lines in file: 17814
 Found 2 dropped records,
 Found 0 comments,
 Found 0 blank records,
 Found 5 corrupted records,
 Found 0 old records,
 Found 17807 new qualified records.
```

Now that we have the tool configured we can go on and schedule it to run as frequently as we need. By default it runs once per day collecting data and generating daily and monthly reports. I will create a script first `/usr/local/bin/awstats_parse_apache_log.sh`:

```bash
#!/bin/bash
 
OTHER_SERVER="<ip-of-other-apache-server>"
APACHE_LOG="/var/log/apache2/access.log"
AWSTATS_LOG="/tmp/awstats.log"
PARSE_LOG="/tmp/parse.log"
 
trap 'rm -rf /tmp/*.$$' 2 3 4 9
 
# Clean up
rm -f $PARSE_LOG $AWSTATS_LOG
 
# Fetch the log from the other server
sudo -u <sudo-user> ssh <sudo-user>@${OTHER_SERVER} "cat $APACHE_LOG" > $PARSE_LOG
 
# Get the local apache log
cat $APACHE_LOG >> $PARSE_LOG
 
# Sort the file by time field since we merge from
# two different servers and the records are out of order
sort -n -t"|" -k17 $PARSE_LOG > /tmp/awstats.log.$$
cat /tmp/awstats.log.$$ > $PARSE_LOG
 
# Parse the log file records and put them in the awstats log file
cat $PARSE_LOG | awk -F \| 'BEGIN{OFS="|"} {if($3 ~ ",") {split($3,a,", "); $3=a[1]} else $3=$3; print $3,$4,$5,"["$10"]",$11,$12,$16,$17,$18,$19,$20}' | sed -e 's/\(.*\)\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)|/\1\2-\3-\4 \5:\6:\7|/' > $AWSTATS_LOG
 
# Update the AWStats database (the LogFile=/tmp/awstats.log in awstats.conf)
/usr/bin/awstats -config=www.mydomain.com -update -showcorrupted -showdropped
 
# Remove the temp file
rm -rf /tmp/*.$$
 
exit 0
```

This script will fetch the Apache log from the peer server, merge it with the local apache log into a single file, sort it by time stamps to avoid awstats complaining about dates out of order and finally parse it and create a new database file. We can also run it as cronjob every 15 minutes lets say to keep the stats more up to date:

```
*/15 * * * * /usr/local/bin/awstats_parse_apache_log.sh
```

To make possible for AWStats to get the data before Apache logs are rotated, we add a `pre-rotate` routine in `/etc/logrotate.d/apache2` just above `postrotate` command:

```
prerotate /usr/local/bin/awstats_parse_apache_log.sh
```

and while we are there, we also change the log rotate frequency from the default weekly to daily.

## Apache setup

Next we need to configure Apache for Awstats and it's web statistics page. Configure Apache and set up our LDAP authentication and authorization so we can protect the access `/etc/apache2/conf-available/awstats.conf`:

```
# AWStats config
Alias /awstatsclasses "/usr/share/awstats/lib/"
Alias /awstats-icon "/usr/share/awstats/icon/"
Alias /awstatscss "/usr/share/doc/awstats/examples/css"
ScriptAlias /awstats/ /usr/lib/cgi-bin/
<Directory "/usr/lib/cgi-bin/">
    Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
    #Require all denied
</Directory>
 
<Files "awstats.pl">
   <RequireAll>
        AuthName AWStats
        AuthType Basic
        AuthBasicProvider ldap
        AuthBasicAuthoritative on
        AuthLDAPURL "ldap://ldap-master.mydomain.com ldap-slave.mydomain.com:389/ou=Users,dc=mydomain,dc=com?uid" STARTTLS
        AuthLDAPBindDN cn=<binduser>,ou=Users,dc=mydomain,dc=com
        AuthLDAPBindPassword <bindpassword>
        AuthLDAPGroupAttribute memberUid
        AuthLDAPGroupAttributeIsDN off
        Require ldap-group cn=mygroup,ou=Groups,dc=mydomain,dc=com
        Require valid-user
        Satisfy all
   </RequireAll>
</Files>
```

Then we load the needed modules, enable the above configuration and restart the service:

```
$ sudo a2enmod ldap
$ sudo a2enmod authnz_ldap
$ sudo a2enmod cgid
$ sudo a2enconf awstats
$ sudo service apache2 restart
```

## Proxy setup

We want the traffic encrypted so we redirect Awstats pages via SSL on the HAproxy load balancer, `/etc/haproxy/haproxy.conf` so we add/modify a following rule:

```
listen http-lb
...
    acl awstats_access path_beg /awstats
    redirect scheme https if awstats_access
...
```

to send the traffic to our SSL listener and then reload the service:

```
$ sudo service haproxy reload
```

## Conclusion

With little bit of work we get a comprehensive and customizable statistics and reporting tool. For example the `%extra2` field I have defined in the LogFormat variable refers to the time taken to serve a request in micro seconds. Based on this filed we can add our own custom section to the report, for example I want a report on URL's that have response time higher than 10 seconds:

```
...
ExtraSectionName1="Response Time (in microseconds)"
ExtraSectionCodeFilter1="200 304"
ExtraSectionCondition1="extra2,^([0-9]{8,})$"
ExtraSectionFirstColumnTitle1="URL"
ExtraSectionFirstColumnValues1="URL,\/"
ExtraSectionFirstColumnFormat1="%s"
ExtraSectionStatTypes1=P
ExtraSectionAddAverageRow1=0
ExtraSectionAddSumRow1=0
MaxNbOfExtra1=200
MinHitExtra1=1
...
#ExtraTrackedRowsLimit=500
ExtraTrackedRowsLimit=1200
...
```

Plus it comes with nice web UI. Who needs Google Analytics, right?