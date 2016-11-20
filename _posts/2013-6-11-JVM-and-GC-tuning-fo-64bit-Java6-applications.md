---
type: posts
header:
  teaser: 'futuristic-banner.jpg'
title: 'JVM and GC tuning for 64 bit Java 6 applications'
categories: 
  - JVM
tags: [jvm, java, gc]
date: 2013-6-11
---
{% include toc %}
This article describes the options used in our production Amazon AWS servers for JVM and GC tuning. It also gives a short overview of the JVM Heap and Garbage Collection and the settings used for our Tomcat application. I've also included some settings that we haven't tested yet but might prove useful in case we need some further enhancements. We are using the concurrent CMS (Concurrent mark-sweep) collector in incremental mode which gives optimal performance on one or two cpu cores. With this collector the garbage in all of the heap memory generations is being collected concurrently to the application threads which guaranties low latency.

Following image represents the JVM memory heap regions as of Oracle JDK 6 and 7:

![JVM heap](/blog/images/Java-Memory-Model.png "JVM heap distribution")

# JVM GC basics

In new `HotSpot` JVMs, the garbage collector divides the heap into 3 generations:

* Young generation - contains newly allocated objects
* Old generation - objects that has survived some number of young gen collections and some very large objects that were directly allocated in old gen
* Permanent generation (perm gen) - contains classes, methods and associated descriptors which are managed by the JVM

The `Young Generation` is further divided into 3 regions. The larger division is known as the `Eden`. This is where almost all the new object allocations take place (under special circumstances, large objects may get allocated in the old generation). The other smaller spaces are known as `survivor spaces`. One of the survivor spaces are always kept empty until the next young generation collection.

When an old generation fills up a full collection (major collection) is performed. All generations are collected during a full collection. First the young generation is collected using the young generation collection algorithm. Then the old generation collection algorithm is run on the old generation and permanent generation. If compaction occurs, each generation is compacted separately. During a full collection if the old generation is too full to accept tenured objects from the young generation, the old generation collection algorithm is run on the entire heap (except with CMS collector).

## Available Garbage Collectors

HotSpot JVM (up to JVM 6) contains 3 garbage collectors:

* Serial collector
* Parallel collector
* Concurrent mark-sweep collector

### Serial Collector (Mark-Sweep-Compact collector)

This is the collector used by default on Java HotSpot client JVM. It is a serial, stop-the-world, copying collector. Because it is serial and operates in the stop-the-world mode it is not a very efficient collector.

### Parallel Collector (Throughput Collector)

This is very similar to the serial collector in many ways. In fact the only notable difference is that parallel collector uses multiple threads to perform the young generation collection. Other than that it uses the same algorithms as the serial collector. The number of threads used for collection is equal to the number of CPUs available. Because of the parallel collection feature, this collector usually results in much shorter pauses and higher application throughput. However note that the old generation collection is still carried out using a single thread in serial fashion. This is the default collector used in Java HotSpot server JVM.

There is enhanced version of the parallel collector called `Parallel Compacting Collector`. It uses multiple threads to perform the old generation collection as well. The old generation collection divides the generations into regions and operate on individual regions in parallel. The algorithm used for old generation collection is also slightly different from what's used in serial and parallel collectors.

### Concurrent Mark-Sweep Collector (CMS Collector)

This is the collector used for our application so I've given it here in more details.

While the parallel collectors give prominence to application throughput, this collector gives prominence to low response time. It uses the same young generation collection algorithm as the parallel collectors. But the old generation collection is performed concurrently with the application instead of going to stop-the-world mode (at least most of the time). A collection cycle starts with a short pause known as the initial mark. This identifies the initial set of live objects directly reachable from the application code. Then during the concurrent marking phase, collector marks all live objects transitively reachable from the initially marked set. Because this happens concurrently with the application not all live objects get marked up. To handle this, the application stops again for a second pause for the remark phase. Remark phase is often run using multiple threads for efficiency. After this marking process a concurrent sweep phase is initiated.

`CMS` collector is not a compacting collector. Therefore it uses a set of free-lists when it comes to allocation. Therefore the allocation overhead is higher. Also CMS collector is best suited for large heaps. Because collection happens concurrently, the old generation will continue to grow even during collection. So the heap should be large enough to accommodate that growth. Another issue with CMS is floating garbage. That is objects considered as live may become garbage towards the end of the collection cycle. These will not get immediately cleaned up but will definitely get cleaned up during the next collection cycle. CMS collector requires lot of CPU power as well.

Unlike other collectors, CMS collector does not wait till the old generation becomes full to start a collection. Instead it starts collecting early so it can avoid old generation getting filled up to the capacity. If the old generation gets filled up before CMS kicks in, it resorts to the serial stop-the-world collection mode used by serial and parallel collectors. To avoid this CMS uses some statistics regarding previous collection times and the time taken to fill up the old generation. CMS also kicks in if the old generation occupancy exceeds a predefined threshold known as the initiating occupancy fraction. This is a configurable parameter and defaults to 68% in JVM 5 but the value is subject to change from release to release. The default value of this initiating occupancy threshold for JVM 6 is approximately 92%, which proved to be much too high for our user case and was one of the crucial settings, together with the New Gen sizing, in our GC tuning.

There is a special mode of operation for the CMS collector known as the `incremental mode`. In the incremental mode, concurrent collection cycles are broken down into smaller chunks. Therefore during a concurrent collection cycle, the collector will suspend itself to give full CPU to the running application. This in turns reduces the impact of long concurrent collection phases. This mode is particularly useful in cases where the number of CPUs is small.

The CMS collector now also uses multiple threads to perform the concurrent marking task in parallel on platforms with multiple processors reducing the duration of the concurrent marking cycle, allowing the collector to support applications with larger numbers of threads and higher object allocation rates.

Finally, given here for the purpose of completeness and better understanding of this complex collector, the CMS collection cycle has following phases:

* Initial mark - this is stop-the-world phase while CMS is collecting root references.
* Concurrent mark - this phase is done concurrently with application, garbage collector traverses though object graph in old space marking live objects.
* Concurrent pre clean - this is another concurrent phase, basically it is another mark phase which will try to account references changed during previous mark phase. Main reason for this phase is reduce time of stop-the-world remark phase.
* Remark – once concurrent mark is finished, garbage collector need one more stop-the-world pause to account references which have been changed during concurrent mark phase.
* Concurrent sweep - garbage collector will scan through whole old space and reclaim space occupied by unreachable objects.
* Concurrent reset - after CMS cycle is finished, some structures have to be reset before next cycle can start.

# Settings

During the GC tuning and testing of our Memory Heap, these are the settings we have finally come up with:

```
JAVA_OPTS="-Denv=PROD -Djava.awt.headless=true -server -d64 -Xms6G -Xmx6G -XX:PermSize=256m -XX:MaxPermSize=512m -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -XX:+CMSIncrementalMode -XX:+CMSPermGenSweepingEnabled -XX:+CMSClassUnloadingEnabled -XX:+CMSParallelRemarkEnabled -XX:+UseCompressedOops -XX:+AggressiveOpts -XX:+DisableExplicitGC -verbose:gc -Xloggc:/var/log/tomcat7/gc.log -XX:+PrintGCDetails -XX:+PrintHeapAtGC -XX:+PrintGCTimeStamps -XX:+PrintTenuringDistribution -XX:+PrintGCApplicationConcurrentTime -XX:+PrintGCApplicationStoppedTime -XX:+CMSConcurrentMTEnabled -XX:CMSFullGCsBeforeCompaction=1 -XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=70 -XX:NewRatio=4 -XX:SurvivorRatio=16"
```

## General settings

```
-server
    Select the Java HotSpot Server VM. On a 64-bit capable jdk only the Java Hotspot Server VM is supported so the -server option is implicit.

-d64
    Run in 64 bit environment (useful for mixed 32 and 64 bit system, if not defined the default 32 bit will be selected).
```

## JVM tuning/optimization for 64 bit Linux

```
-XX:+UseCompressedOops
    Can improve performance of the 64-bit JRE when the Java object heap is less than 32 gigabytes in size. In this case, HotSpot compresses object references to 32 bits, reducing the amount of data that it must process.
 
-XX:+AggressiveOpts
    Turn on point performance compiler optimizations that are expected to be default in upcoming releases.
 
-XX:+UseCompressedStrings (not used atm)
    Use a byte[] for Strings which can be represented as pure ASCII.
 
-XX:+OptimizeStringConcat (not used atm)
    Optimize String concatenation operations where possible.
 
-XX:+UseStringCache (not used atm)
    Enables caching of commonly allocated strings.
```

## Memory heap sizing

```
-Xms6G -Xmx6G
    The start size and max heap size
```

## Enable verbose GC logging

```
-verbose:gc -Xloggc:/var/log/tomcat7/gc.log -XX:+PrintGCDetails -XX:+PrintHeapAtGC -XX:+PrintGCTimeStamps -XX:+PrintTenuringDistribution -XX:+PrintGCApplicationConcurrentTime -XX:+PrintGCApplicationStoppedTime
    These options will log some details about the GC runs like how long a specific GC took and the memory space sizes before and after the GC. This is going to be logged in "/var/log/tomcat7/gc.log" file which can grow pretty fast so I have set logrotate to rotate and compress this file on daily bases.
```

We need to setup Logrotate `/etc/logrotate.d/gc` file since the GC file can grow very big very fast depending on the verbosity:
 
```
/var/log/tomcat7/gc.log {
    daily
    copytruncate
    rotate 30
    compress
    missingok
    notifempty
    create 0664 tomcat7 tomcat7
}
```

### GC Examples

Example1: Full GC

```
46251.594: [Full GC 46251.594: [CMS: 389595K->326310K(6990528K), 2.6907500 secs] 613656K->326310K(8310976K), [CMS Perm : 523866K->136182K(524288K)] icms_dc=0 , 2.6910460 secs] [Times: user=2.68 sys=0.01, real=2.69 secs]
Heap after GC invocations=250 (full 3):
 par new generation   total 1320448K, used 0K [0x00000005e0000000, 0x0000000635550000, 0x0000000635550000)
  eden space 1242816K,   0% used [0x00000005e0000000, 0x00000005e0000000, 0x000000062bdb0000)
  from space 77632K,   0% used [0x0000000630980000, 0x0000000630980000, 0x0000000635550000)
  to   space 77632K,   0% used [0x000000062bdb0000, 0x000000062bdb0000, 0x0000000630980000)
 concurrent mark-sweep generation total 6990528K, used 326310K [0x0000000635550000, 0x00000007e0000000, 0x00000007e0000000)
 concurrent-mark-sweep perm gen total 524288K, used 136182K [0x00000007e0000000, 0x0000000800000000, 0x0000000800000000)
}
```

Example2: Minor GC

```
63590.845: [GC 63590.845: [ParNew
Desired survivor size 39747584 bytes, new threshold 6 (max 15)
- age   1:   24652352 bytes,   24652352 total
- age   2:    4938016 bytes,   29590368 total
- age   3:    3409880 bytes,   33000248 total
- age   4:      23112 bytes,   33023360 total
- age   5:      13464 bytes,   33036824 total
- age   6:    7997224 bytes,   41034048 total
: 1300003K->54080K(1320448K), 0.1905130 secs] 1860366K->618607K(8310976K) icms_dc=0 , 0.1913710 secs] [Times: user=0.29 sys=0.00, real=0.20 secs]
Heap after GC invocations=567 (full 6):
 par new generation   total 1320448K, used 54080K [0x00000005e0000000, 0x0000000635550000, 0x0000000635550000)
  eden space 1242816K,   0% used [0x00000005e0000000, 0x00000005e0000000, 0x000000062bdb0000)
  from space 77632K,  69% used [0x0000000630980000, 0x0000000633e503a8, 0x0000000635550000)
  to   space 77632K,   0% used [0x000000062bdb0000, 0x000000062bdb0000, 0x0000000630980000)
 concurrent mark-sweep generation total 6990528K, used 564527K [0x0000000635550000, 0x00000007e0000000, 0x00000007e0000000)
 concurrent-mark-sweep perm gen total 524288K, used 295145K [0x00000007e0000000, 0x0000000800000000, 0x0000000800000000)
}
{Heap before GC invocations=567 (full 6):
 par new generation   total 1320448K, used 1296896K [0x00000005e0000000, 0x0000000635550000, 0x0000000635550000)
  eden space 1242816K, 100% used [0x00000005e0000000, 0x000000062bdb0000, 0x000000062bdb0000)
  from space 77632K,  69% used [0x0000000630980000, 0x0000000633e503a8, 0x0000000635550000)
  to   space 77632K,   0% used [0x000000062bdb0000, 0x000000062bdb0000, 0x0000000630980000)
 concurrent mark-sweep generation total 6990528K, used 564527K [0x0000000635550000, 0x00000007e0000000, 0x00000007e0000000)
 concurrent-mark-sweep perm gen total 524288K, used 297159K [0x00000007e0000000, 0x0000000800000000, 0x0000000800000000)
```

Example 3: CMS collection phases

```
31.953: [GC [1 CMS-initial-mark: 0K(6990528K)] 577732K(8310976K), 0.3759070 secs] [Times: user=0.38 sys=0.00, real=0.38 secs]
32.336: [CMS-concurrent-mark-start]
32.557: [CMS-concurrent-mark: 0.221/0.221 secs] [Times: user=0.40 sys=0.04, real=0.22 secs]
32.557: [CMS-concurrent-preclean-start]
32.638: [CMS-concurrent-preclean: 0.081/0.081 secs] [Times: user=0.16 sys=0.00, real=0.08 secs]
32.638: [CMS-concurrent-abortable-preclean-start]
{Heap before GC invocations=1 (full 1):
 par new generation   total 1320448K, used 1258177K [0x00000005e0000000, 0x0000000635550000, 0x0000000635550000)
  eden space 1242816K, 100% used [0x00000005e0000000, 0x000000062bdb0000, 0x000000062bdb0000)
  from space 77632K,  19% used [0x0000000630980000, 0x0000000631880578, 0x0000000635550000)
  to   space 77632K,   0% used [0x000000062bdb0000, 0x000000062bdb0000, 0x0000000630980000)
 concurrent mark-sweep generation total 6990528K, used 0K [0x0000000635550000, 0x00000007e0000000, 0x00000007e0000000)
 concurrent-mark-sweep perm gen total 262144K, used 54590K [0x00000007e0000000, 0x00000007f0000000, 0x0000000800000000)
```

## CMS collector and GC settings

```
-XX:+UseConcMarkSweepGC
    Use the CMS collector which works concurrently with the application threads without stopping them (except in the mark and remark phases).
 
-XX:+CMSIncrementalMode
    Enable the CMS incremental collector mode, this is recommended CMS collections mode for machines with 1 or 2 low power processors. The major CMS collections will happen in steps instead in one large sweep thus reducing the latency.
 
-XX:+CMSIncrementalPacing (not used atm)
    This flag enables automatic adjustment of the incremental mode duty cycle based on statistics collected while the JVM is running.
 
-XX:+CMSClassUnloadingEnabled
    Use the CMS collector to unload the unused classes in the Perm Gen.
 
-XX:+CMSPermGenSweepingEnabled
    Collect the Perm Gen objects too during the CMS phase.
 
-XX:+CMSParallelRemarkEnabled
    Use multiple threads (equal to number of CPU's) for the stop-the-world marking phase of the CMS collector.
 
-XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=70
    Threshold to start the CMS collection, this is by default 92% and we don't want to wait that long but start at 70%.
 
-XX:+UseParNewGC
    Use parallel threads for the New Gen collection.
 
-XX:+CMSConcurrentMTEnabled
    Whether multi-threaded concurrent work enabled (if ParNewGC).
 
-XX:CMSFullGCsBeforeCompaction=1
    It tells the CMS collector to always complete the collection before it starts a new one. Without this, we can run into the situation where it throws a bunch of work away and starts again.
 
-XX:+DisableExplicitGC
    Disable the explicit GC, will disable the system and application gc calls.
```

## New Gen space sizing

```
-XX:NewRatio=5
    Set the New Gen (Eden plus 2 survivor spaces) to 1/6 of the whole heap size.
 
-XX:SurvivorRatio=16
    Set each of the survivor spaces (S0 and S1) to be 1/16 of the New Gen space.
```

## Perm Gen sizing

```
-XX:PermSize=256m -XX:MaxPermSize=512m
```

## In case we want to test the Parallel (throughput) collector

In this case we need to substitute the above given CMS collector settings with the following `Parallel Collector` settings and it's compacting function:

```
-XX:+UseParallelGC -XX:+UseParallelOldGC -XX:+AggressiveHeap -XX:+UseAdaptiveSizePolicy
```

where `UseAdaptiveSizePolicy` setting is enabled by default since Java 1.5 and doesn't need to be explicitly included as an option above.

# Monitoring and troubleshooting

The Oracle (Sun) JDK offers many useful tools for monitoring and troubleshooting the JVM HotSpot like `jinfo`, `jstat`, `jmap`, `jps`, `jstack` and `jhat`. Some examples are given below.

Set JAVA_HOME:

```
export JAVA_HOME=/usr/lib/jvm/java-6-oracle
export PATH=$PATH:$JAVA_HOME/bin
```

We can permanently set this options in our home dir `~/.bashrc` file lets say in case our default shell is bash.

Collect information for the Java process:

```
$ jinfo <pid>
```

Monitor the GC in 5 seconds intervals:

```
$ jstat -gccause <pid> 5000
$ jstat -gc <pid> 5000
```

Same but also print the time stamp and the header line every 20 cycles (showing individual options for GC utilization, new gen and old gen stats):

```
$ jstat -gcutil -h20 -t <pid> 5000
$ jstat -gcnew -h20 -t <pid> 5000
$ jstat -gcold -h20 -t <pid> 5000
```

Print the Perm Gen stats, the classes histogram and the heap distribution details:

```
$ jmap -F -permstat -J-d64 <pid>
$ jmap -F -histo -J-d64 <pid>
$ jmap -F -heap -J-d64 <pid>
```

Thread dump:

```
$ jstak -m -F <pid>
```

Additionally using `jmap` with `-dump` option we can take a thread dump of the JVM in binary format which can be feed through `jhat` for profiling. More details can be found in the `PDF troubleshooting guide` from one of the links in the `Reference` section below.

# Conclusion

Finding the appropriate GC settings is usually long and time consuming process. It needs individual testing for each option introduced on **trial and fail** bases and usually can take couple of days or even weeks to come up with the perfect tuning. The fact is every application is different and there is no such thing as one fits all. What is good for one app may be completely wrong for another. There is a new `G1` non-generational collector introduced in Java 7 which might be worth trying in near future.

# References and further reading

* [Java SE 6 HotSpot Virtual Machine Garbage Collection Tuning](http://www.oracle.com/technetwork/java/javase/gc-tuning-6-140523.html)
* [Understanding GC pauses in JVM hotspots](http://blog.griddynamics.com/2011/06/understanding-gc-pauses-in-jvm-hotspots_02.html)
* [Java HotSpot VM Options](http://www.oracle.com/technetwork/java/javase/tech/vmoptions-jsp-140102.html)
* [JVM troubleshooting guide](http://www.oracle.com/technetwork/java/javase/tsg-vm-149989.pdf)
* [Memory Leak Protection](http://wiki.apache.org/tomcat/MemoryLeakProtection)