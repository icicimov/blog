---
type: posts
header:
  teaser: 'cloud-computing.jpg'
title: 'Geo Location with HAProxy'
categories: 
  - DevOps
tags: [aws, haproxy, geoip]
date: 2017-6-21
---

Often there might be need to allow, block or redirect users based on the country or continent they come from. This is how to do it with HAProxy.

First get the iprange tool from the haproxy contrib repository [](https://github.com/haproxy/haproxy/tree/master/contrib/iprange), run make and copy the created binary somewhere in the `$PATH` like `/usr/local/bin/iprange`.

We can download the Maxmind database file from [](http://geolite.maxmind.com/download/geoip/database/GeoIPCountryCSV.zip) (although the script can do this part for us too) and run the attached script [haproxy-geoip.sh]({{ site.baseurl }}/download/haproxy-geoip.sh):

```
$ mkdir -p /etc/haproxy/geoip && cd /etc/haproxy/geoip
$ bash haproxy-geoip.sh -i GeoIPCountryCSV.zip > geoip.txt
```

This will create our rather large geoip.txt file with entries that look like this:

```
1.0.0.0/24 AU
1.0.1.0/24 CN
1.0.2.0/23 CN
1.0.4.0/22 AU
1.0.8.0/21 CN
1.0.16.0/20 JP
1.0.32.0/19 CN
1.0.64.0/18 JP
1.0.128.0/17 TH
...
```

Next we create various db files we can use with ACLs in our haproxy configuration. Start by create the GeoIP country per continent text file(s). The Maxmind continents file looks like this:

```
$ more country_continent.csv
"iso 3166 country","continent code"
A1,--
A2,--
AD,EU
AE,AS
AF,AS
AG,NA
AI,NA
AL,EU
AM,AS
AN,NA
...
```

so we need to convert it into more friendly format first:

```
$ wget http://dev.maxmind.com/static/csv/codes/country_continent.csv
$ for c in `grep -E -v "\-|iso" country_continent.csv | sort -t',' -k 2` ; do echo $c | awk -F',' '{ print $1 >> $2".continent" }' ; done
$ ls -1 *.continent
AF.continent
AN.continent
AS.continent
EU.continent
NA.continent
OC.continent
SA.continent
```

Next we create the GeoIP subnets per country files:

```
$ cut -d, -f1,2,5 GeoIPCountryWhois.csv | iprange | sed 's/"//g' | awk -F' ' '{ print $1 >> $2".subnets" }'
```

and check the result files:

```
$ ls *.subnets
A1.subnets  AU.subnets  BN.subnets  CI.subnets  DK.subnets  FM.subnets  GQ.subnets  IM.subnets  KM.subnets  LU.subnets  MP.subnets  NG.subnets  PL.subnets  SB.subnets  ST.subnets  TO.subnets  VG.subnets A2.subnets  AW.subnets  BO.subnets  CK.subnets  DM.subnets  FO.subnets  GR.subnets  IN.subnets  KN.subnets  LV.subnets  MQ.subnets  NI.subnets  PM.subnets  SC.subnets  SV.subnets  TR.subnets  VI.subnets  AD.subnets  AX.subnets  BQ.subnets  CL.subnets  DO.subnets  FR.subnets  GS.subnets  IO.subnets  KP.subnets  LY.subnets  MR.subnets  NL.subnets  PN.subnets  SD.subnets  SX.subnets  TT.subnets  VN.subnets  AE.subnets  AZ.subnets  BR.subnets  CM.subnets  DZ.subnets  GA.subnets  GT.subnets  IQ.subnets  KR.subnets  MA.subnets  MS.subnets  NO.subnets  PR.subnets  SE.subnets  SY.subnets  TV.subnets  VU.subnets  AF.subnets  BA.subnets  BS.subnets  CN.subnets  EC.subnets  GB.subnets  GU.subnets  IR.subnets  KW.subnets  MC.subnets  MT.subnets  NP.subnets  PS.subnets  SG.subnets  SZ.subnets  TW.subnets  WF.subnets  AG.subnets  BB.subnets  BT.subnets  CO.subnets  EE.subnets  GD.subnets  GW.subnets  IS.subnets  KY.subnets  MD.subnets  MU.subnets  NR.subnets  PT.subnets  SH.subnets  TC.subnets  TZ.subnets  WS.subnets  AI.subnets  BD.subnets  BW.subnets  CR.subnets  EG.subnets  GE.subnets  GY.subnets  IT.subnets  KZ.subnets  ME.subnets  MV.subnets  NU.subnets  PW.subnets  SI.subnets  TD.subnets  UA.subnets  YE.subnets  AL.subnets  BE.subnets  BY.subnets  CU.subnets  EH.subnets  GF.subnets  HK.subnets  JE.subnets  LA.subnets  MF.subnets  MW.subnets  NZ.subnets  PY.subnets  SJ.subnets  TF.subnets  UG.subnets  YT.subnets  AM.subnets  BF.subnets  BZ.subnets  CV.subnets  ER.subnets  GG.subnets  HN.subnets  JM.subnets  LB.subnets  MG.subnets  MX.subnets  OM.subnets  QA.subnets  SK.subnets  TG.subnets  UM.subnets  ZA.subnets  AO.subnets  BG.subnets  CA.subnets  CW.subnets  ES.subnets  GH.subnets  HR.subnets  JO.subnets  LC.subnets  MH.subnets  MY.subnets  PA.subnets  RE.subnets  SL.subnets  TH.subnets  US.subnets  ZM.subnets  AP.subnets  BH.subnets  CC.subnets  CX.subnets  ET.subnets  GI.subnets  HT.subnets  JP.subnets  LI.subnets  MK.subnets  MZ.subnets  PE.subnets  RO.subnets  SM.subnets  TJ.subnets  UY.subnets  ZW.subnets  AQ.subnets  BI.subnets  CD.subnets  CY.subnets  EU.subnets  GL.subnets  HU.subnets  KE.subnets  LK.subnets  ML.subnets  NA.subnets  PF.subnets  RS.subnets  SN.subnets  TK.subnets  UZ.subnets  AR.subnets  BJ.subnets  CF.subnets  CZ.subnets  FI.subnets  GM.subnets  ID.subnets  KG.subnets  LR.subnets  MM.subnets  NC.subnets  PG.subnets  RU.subnets  SO.subnets  TL.subnets  VA.subnets  AS.subnets  BL.subnets  CG.subnets  DE.subnets  FJ.subnets  GN.subnets  IE.subnets  KH.subnets  LS.subnets  MN.subnets  NE.subnets  PH.subnets  RW.subnets  SR.subnets  TM.subnets  VC.subnets  AT.subnets  BM.subnets  CH.subnets  DJ.subnets  FK.subnets  GP.subnets  IL.subnets  KI.subnets  LT.subnets  MO.subnets  NF.subnets  PK.subnets  SA.subnets  SS.subnets  TN.subnets  VE.subnets
```

Finally, we create subnets per continent files:

```
$ for f in `ls *.continent`; do for c in $(cat $f); do [[ -f ${c}.subnets ]] && cat ${c}.subnets >> ${f%%.*}.txt; done; done
$ ls -1 [A-Z]{2}.txt
AF.txt
AN.txt
AS.txt
EU.txt
NA.txt
OC.txt
SA.txt
```

Now we have all files needed to work with any combination of country or continent in our access control rules.

# Usage

Example of usage of the subnet per continent files we created would be creating the following ACLs:

```
acl acl_AF src -f AF.txt
acl acl_AN src -f AN.txt
acl acl_AS src -f AS.txt
acl acl_EU src -f EU.txt
acl acl_NA src -f NA.txt
acl acl_OC src -f OC.txt
acl acl_SA src -f SA.txt
```

and then using them to allow or decline clients based on the continent they come from, for example:

```
http-request deny if !acl_EU
```

Or send them to different backend servers:

```
use_backend bk_af if acl_AF
```

Allow acces from Ireland, UK or AU only:

```
acl acl_geoloc_uk_au src,map_ip(/etc/haproxy/geoip/geoip.txt) -m reg -i (IE|GB|AU)
http-request deny if !acl_geoloc_uk_au
```

The options are many and HAProxy is really good in parsing large files with hundreds of thousands records so no impact on the performance.