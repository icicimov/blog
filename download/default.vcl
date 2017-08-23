#
# This is an example VCL file for Varnish.
#
# It does not do anything by default, delegating control to the
# builtin VCL. The builtin VCL is called when there is no explicit
# return statement.
#
# See the VCL chapters in the Users Guide at https://www.varnish-cache.org/docs/
# and https://www.varnish-cache.org/trac/wiki/VCLExamples for more examples.
 
# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.0 format.
vcl 4.0;
 
import std;
import directors;
 
# Default backend definition. Set this to point to your content server.
backend default {
    .host = "127.0.0.1";
    .port = "8080";
}
 
backend bk_tomcats_1 {
    .host = "10.77.3.227";
    .port = "8080";
    .connect_timeout = 3s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
    .max_connections = 100;
    .probe = {
        #.url = "/haproxycheck";
        .request =
          "GET /encompass/healthcheck HTTP/1.1"
          "Host: domain.encompasshost.com"
          "Connection: close"
          "User-Agent: Varnish Health Probe";
        .expected_response = 200;
        .timeout = 1s;
        .interval = 5s;
        .window = 2;
        .threshold = 2;
        .initial = 2;
    }
}
 
backend bk_tomcats_2 {
    .host = "10.77.4.234";
    .port = "8080";
    .connect_timeout = 3s;
    .first_byte_timeout = 10s;
    .between_bytes_timeout = 5s;
    .max_connections = 100;
    .probe = {
        #.url = "/haproxycheck";
        .request =
          "GET /encompass/healthcheck HTTP/1.1"
          "Host: domain.encompasshost.com"
          "Connection: close"
          "User-Agent: Varnish Health Probe";
        .expected_response = 200;
        .timeout = 1s;
        .interval = 5s;
        .window = 2;
        .threshold = 2;
        .initial = 2;
    }
}
 
acl purge {
    "localhost";
    "127.0.0.1"/8;
    "10.77.3.0"/20; /* and everyone on the local network */
    ! "192.168.1.23"; /* except for the dialin router */
}
 
sub vcl_init {
    # Called when VCL is loaded, before any requests pass through it.
    # Typically used to initialize VMODs.
 
    new vdir = directors.round_robin();
    vdir.add_backend(bk_tomcats_1);
    vdir.add_backend(bk_tomcats_2);
}
 
sub vcl_recv {
    # Happens before we check if we have this in cache already.
    #
    # Typically you clean up the request here, removing cookies you don't need,
    # rewriting the request, etc.
 
    set req.backend_hint = vdir.backend(); # send all traffic to the vdir director
 
    # Normalize the header, remove the port (in case you're testing this on various TCP ports)
    set req.http.Host = regsub(req.http.Host, ":[0-9]+", "");
 
    # Remove the proxy header (see https://httpoxy.org/#mitigate-varnish)
    unset req.http.proxy;
 
    # Normalize the query arguments
    set req.url = std.querysort(req.url);
 
    # Health Checking
    if (req.url == "/varnishcheck") {
        return(synth(751, "health check OK!"));
    }
 
    # Don't cache POST requests
    if (req.http.Authorization || req.method == "POST") {
        return (pass);
    }
 
    # Cache only GET and HEAD requests by default
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
 
    # Remove all cookies for static files, force a cache hit
    if (req.url ~ "^[^?]*\.(css|jp(e)?g|js|gif|png|swf|ico|xml|flv|gz|txt|...)(\?.*)?$") {
        unset req.http.Cookie;
    }
 
    # Only deal with sane method types
    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "PATCH" &&
        req.method != "DELETE") {
        /* Non-RFC2616 or CONNECT which is weird. */
        return (pipe);
    }
 
    # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
    if (req.http.Upgrade ~ "(?i)websocket") {
        return (pipe);
    }
 
    # Purge request
    if (req.method == "PURGE") {
        if (client.ip ~ purge) {
          return(purge);
        } else {
          return(synth(403, "Access denied."));
        }
    }
 
    # Accept-Encoding header clean-up
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)") {
            unset req.http.Accept-Encoding;
        # use gzip when possible, otherwise use deflate
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            # unknown algorithm, remove accept-encoding header
            unset req.http.Accept-Encoding;
        }
  
        # Microsoft Internet Explorer 6 is well know to be buggy with compression and css / js
        if (req.url ~ ".(css|js)" && req.http.User-Agent ~ "MSIE 6") {
            unset req.http.Accept-Encoding;
        }
    }
 
    ## Cookies manipulation ##
 
    # Remove the "has_js" cookie
    set req.http.Cookie = regsuball(req.http.Cookie, "has_js=[^;]+(; )?", "");
 
    # Remove any Google Analytics based cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");
 
    # Remove DoubleClick offensive cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");
 
    # Remove the Quant Capital cookies (added by some plugin, all __qca)
    set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");
 
    # Remove the AddThis cookies
    set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");
 
    # Remove a ";" prefix in the cookie if present
    set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");
 
    # Are there cookies left with only spaces or that are empty?
    if (req.http.cookie ~ "^\s*$") { unset req.http.cookie; }
 
    if (req.http.Cache-Control ~ "(?i)no-cache") {
    #if (req.http.Cache-Control ~ "(?i)no-cache" && client.ip ~ editors) { # create the acl editors if you want to restrict the Ctrl-F5
    # http://varnish.projects.linpro.no/wiki/VCLExampleEnableForceRefresh
    # Ignore requests via proxy caches and badly behaved crawlers
    # like msnbot that send no-cache with every request.
        if (! (req.http.Via || req.http.User-Agent ~ "(?i)bot" || req.http.X-Purge)) {
          #set req.hash_always_miss = true; # Doesn't seems to refresh the object in the cache
          return(purge); # Couple this with restart in vcl_purge and X-Purge header to avoid loops
        }
    }
 
    # If we arrive here, we look for the object in the cache
    return (hash);
}
 
sub vcl_hash {
    # Called after vcl_recv to create a hash value for the request. This is used as a key
    # to look up the object in Varnish.
 
    hash_data(req.url);
 
    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }
 
    # If the client supports compression, keep that in a different cache
    if (req.http.Accept-Encoding) {
        hash_data(req.http.Accept-Encoding);
    }
 
    # Hash cookies for requests that have them
    #if (req.http.Cookie) {
    #    hash_data(req.http.Cookie);
    #}
 
    return (lookup);
}
 
sub vcl_backend_response {
    # Happens after we have read the response headers from the backend.
    #
    # Here you clean the response headers, removing silly Set-Cookie headers
    # and other mistakes your backend does.
 
    # Enable cache for all static files
    # The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
    # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
    if (bereq.url ~ "^[^?]*\.(7z|avi|bmp|bz2|css|csv|doc|docx|eot|flac|flv|gif|gz|ico|jpeg|jpg|js|less|mka|mkv|mov|mp3|mp4|mpeg|mpg|odt|otf|ogg|ogm|opus|pdf|png|ppt|pptx|rar|rtf|svg|svgz|swf|tar|tbz|tgz|ttf|txt|txz|wav|webm|webp|woff|woff2|xls|xlsx|xml|xz|zip)(\?.*)?$") {
        unset beresp.http.set-cookie;
    }
 
    # Large static files are delivered directly to the end-user without
    # waiting for Varnish to fully read the file first.
    # Varnish 4 fully supports Streaming, so use streaming here to avoid locking.
    if (bereq.url ~ "^[^?]*\.(7z|avi|bz2|flac|flv|gz|mka|mkv|mov|mp3|mp4|mpeg|mpg|ogg|ogm|opus|rar|tar|tgz|tbz|txz|wav|webm|xz|zip)(\?.*)?$") {
        unset beresp.http.set-cookie;
        set beresp.do_stream = true;  # Check memory usage it'll grow in fetch_chunksize blocks (128k by default) if the backend doesn't send a Content-Length header, so only enable it for big objects
    }
 
    # Sometimes, a 301 or 302 redirect formed via Apache's mod_rewrite can mess with the HTTP port that is being passed along.
    # This often happens with simple rewrite rules in a scenario where Varnish runs on :80 and Apache on :8080 on the same box.
    # A redirect can then often redirect the end-user to a URL on :8080, where it should be :80.
    # This may need finetuning on your setup.
    #
    # To prevent accidental replace, we only filter the 301/302 redirects for now.
    if (beresp.status == 301 || beresp.status == 302) {
        set beresp.http.Location = regsub(beresp.http.Location, ":[0-9]+", "");
    }
 
    # Set 2min cache if unset for static files
    if (beresp.ttl <= 0s || beresp.http.Set-Cookie || beresp.http.Vary == "*") {
        set beresp.ttl = 120s; # Important, you shouldn't rely on this, SET YOUR HEADERS in the backend
        set beresp.uncacheable = true;
        return (deliver);
    }
 
    # Don't cache 50x responses
    if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504) {
        return (abandon);
    }
 
    # Allow stale content, in case the backend goes down.
    # make Varnish keep all objects for 6 hours beyond their TTL
    set beresp.grace = 6h;
 
    return (deliver);
}
 
sub vcl_deliver {
    # Happens when we have all the pieces we need, and are about to send the
    # response to the client.
    #
    # You can do accounting or modifying the final object here.
 
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.Via;
    unset resp.http.X-Varnish;
    unset resp.http.Link;
    unset resp.http.X-Generator;
  
    # could be useful to know if the object was in cache or not
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
 
    # The number of hits for the object, may not be very accurate
    set resp.http.X-Cache-Hits = obj.hits;
 
    return (deliver);
}
 
sub vcl_purge {
    # Only handle actual PURGE HTTP methods, everything else is discarded
    if (req.method != "PURGE") {
        # Restart request
        set req.http.X-Purge = "Yes";
        # The restart return action allows Varnish to re-run the VCL state machine with different variables.
        # This is useful in combination with PURGE, in the way that a purged object can be immediately
        # restored with a new fetched object.
        return(restart);
    }
}
 
sub vcl_synth {
    # Health check
    if (resp.status == 751) {
        set resp.status = 200;
        return (deliver);
    } elseif (resp.status == 720) {
        # We use this special error status 720 to force redirects with 301 (permanent) redirects
        # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
        set resp.http.Location = resp.reason;
        set resp.status = 301;
        return (deliver);
    } elseif (resp.status == 721) {
        # And we use error status 721 to force redirects with a 302 (temporary) redirect
        # To use this, call the following from anywhere in vcl_recv: return (synth(720, "http://host/new.html"));
        set resp.http.Location = resp.reason;
        set resp.status = 302;
        return (deliver);
    }
 
    return (deliver);
}
 
sub vcl_pipe {
  # Called upon entering pipe mode.
  # In this mode, the request is passed on to the backend, and any further data from both the client
  # and backend is passed on unaltered until either end closes the connection. Basically, Varnish will
  # degrade into a simple TCP proxy, shuffling bytes back and forth. For a connection in pipe mode,
  # no other VCL subroutine will ever get called after vcl_pipe.
 
  # Note that only the first request to the backend will have
  # X-Forwarded-For set.  If you use X-Forwarded-For and want to
  # have it set for all requests, make sure to have:
  # set bereq.http.connection = "close";
  # here.  It is not set by default as it might break some broken web
  # applications, like IIS with NTLM authentication.
 
  # set bereq.http.Connection = "Close";
 
  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
  }
 
  return (pipe);
} 