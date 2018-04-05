# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(abs_path realpath cwd);
use File::Basename;

#worker_connections(10140);
#workers(1);
#log_level('warn');
#master_on();

repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 1);

our $CWD = cwd();

no_long_string();
#no_diff();

env_to_nginx("PATH=" . $ENV{'PATH'});
$ENV{TEST_NGINX_LUA_PACKAGE_PATH} = "$::CWD/lib/?.lua;;";
$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

$ENV{TEST_NGINX_MEMCACHED_PORT} ||= 11211;
$ENV{TEST_NGINX_RESOLVER} ||= '8.8.8.8';
$ENV{TEST_NGINX_CERT_DIR} ||= dirname(realpath(abs_path(__FILE__)));
$ENV{TEST_NGINX_SERVER_SSL_PORT} ||= 4443;

run_tests();

__DATA__

=== TEST 1: get resume session id serialized
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACKAGE_PATH";
    ssl_session_fetch_by_lua_block {
        local ssl = require "ngx.ssl.session"
        local sid = ssl.get_session_id()
        print("session id: ", sid)
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_session_tickets off;
        ssl_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
        ssl_certificate_key $TEST_NGINX_CERT_DIR/cert/test.key;

        server_tokens off;
    }
--- config
    server_tokens off;
    resolver $TEST_NGINX_RESOLVER;
    lua_ssl_trusted_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
    lua_ssl_verify_depth 3;

    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;

        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(5000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(package.loaded.session, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                package.loaded.session = sess

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: userdata
close: 1 nil

--- grep_error_log eval
qr/ssl_session_fetch_by_lua_block:\d+: session id: [a-fA-f\d]+/s

--- grep_error_log_out eval
[
'',
qr/ssl_session_fetch_by_lua_block:4: session id: [a-fA-f\d]+/s,
qr/ssl_session_fetch_by_lua_block:4: session id: [a-fA-f\d]+/s,
]

--- no_error_log
[alert]
[emerg]
[error]



=== TEST 2: attempt to fetch new session in lua_ctx during resumption.
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACKAGE_PATH";
    ssl_session_fetch_by_lua_block {
        local ssl = require "ngx.ssl.session"
        local sess, err = ssl.get_serialized_session()
        if sess then
           print("session size: ", #sess)
        end

        if err then
           print("get session error: ", err)
        end
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;
        ssl_session_tickets off;
        ssl_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
        ssl_certificate_key $TEST_NGINX_CERT_DIR/cert/test.key;

        server_tokens off;
    }
--- config
    server_tokens off;
    resolver $TEST_NGINX_RESOLVER;
    lua_ssl_trusted_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
    lua_ssl_verify_depth 3;

    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;

        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(5000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(package.loaded.session, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                package.loaded.session = sess

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: userdata
close: 1 nil

--- grep_error_log eval
qr/ssl_session_fetch_by_lua:\d: session size: [a-fA-f\d]+|get session error: bad session in lua context/s

--- grep_error_log_out eval
[
'',
'get session error: bad session in lua context
',
'get session error: bad session in lua context
',
]

--- no_error_log
[alert]
[emerg]
[error]



=== TEST 3: store new session, and resume it
Use a tmp file to store and resume session. This is for testing only.
In practice, never store session in plaintext on persistent storage.
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACKAGE_PATH";
    ssl_session_store_by_lua_block {
        local ssl = require "ngx.ssl.session"

        local sid = ssl.get_session_id()
        print("session id: ", sid)
        local sess = ssl.get_serialized_session()
        print("session size: ", #sess)

        local f = assert(io.open("$TEST_NGINX_SERVER_ROOT/html/session.tmp", "w"))
        f:write(sess)
        f:close()
    }

    ssl_session_fetch_by_lua_block {
        local ssl = require "ngx.ssl.session"
        local sid = ssl.get_session_id()
        print("session id: ", sid)
        local f = assert(io.open("$TEST_NGINX_SERVER_ROOT/html/session.tmp"))
        local sess = f:read("*a")
        f:close()
        ssl.set_serialized_session(sess)
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;

        ssl_session_tickets off;
        ssl_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
        ssl_certificate_key $TEST_NGINX_CERT_DIR/cert/test.key;

        server_tokens off;
    }
--- config
    server_tokens off;
    resolver $TEST_NGINX_RESOLVER;
    lua_ssl_trusted_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
    lua_ssl_verify_depth 3;

    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;

        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(5000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(package.loaded.session, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                package.loaded.session = sess

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: userdata
close: 1 nil

--- grep_error_log eval
qr/ssl_session_(fetch|store)_by_lua_block:\d+: session id: [a-fA-F\d]+/s

--- grep_error_log_out eval
[
qr/ssl_session_store_by_lua_block:5: session id: [a-fA-F\d]+/s,
qr/ssl_session_fetch_by_lua_block:4: session id: [a-fA-F\d]+/s,
qr/ssl_session_fetch_by_lua_block:4: session id: [a-fA-F\d]+/s,
]

--- no_error_log
[alert]
[emerg]
[error]



=== TEST 4: attempt to resume a corrupted session
Session resumption should fail, but the handshake should be
able to carry on and negotiate a new session.
--- http_config
    lua_package_path "$TEST_NGINX_LUA_PACKAGE_PATH";
    ssl_session_store_by_lua_block {
        local ssl = require "ngx.ssl.session"

        local sid = ssl.get_session_id()
        print("session id: ", sid)
    }

    ssl_session_fetch_by_lua_block {
        local ssl = require "ngx.ssl.session"
        local sid = ssl.get_session_id()
        print("session id: ", sid)
        local sess = "==garbage data=="
        local ok, err = ssl.set_serialized_session(sess)
        if not ok or err then
           print("failed to resume session: ", err)
        end
    }

    server {
        listen unix:$TEST_NGINX_HTML_DIR/nginx.sock ssl;
        server_name test.com;

        ssl_session_tickets off;
        ssl_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
        ssl_certificate_key $TEST_NGINX_CERT_DIR/cert/test.key;

        server_tokens off;
    }
--- config
    server_tokens off;
    resolver $TEST_NGINX_RESOLVER;
    lua_ssl_trusted_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
    lua_ssl_verify_depth 3;

    location /t {
        set $port $TEST_NGINX_MEMCACHED_PORT;

        content_by_lua_block {
            do
                local sock = ngx.socket.tcp()

                sock:settimeout(5000)

                local ok, err = sock:connect("unix:$TEST_NGINX_HTML_DIR/nginx.sock")
                if not ok then
                    ngx.say("failed to connect: ", err)
                    return
                end

                ngx.say("connected: ", ok)

                local sess, err = sock:sslhandshake(package.loaded.session, "test.com", true)
                if not sess then
                    ngx.say("failed to do SSL handshake: ", err)
                    return
                end

                ngx.say("ssl handshake: ", type(sess))

                package.loaded.session = sess

                local ok, err = sock:close()
                ngx.say("close: ", ok, " ", err)
            end  -- do
        }
    }

--- request
GET /t
--- response_body
connected: 1
ssl handshake: userdata
close: 1 nil

--- grep_error_log eval
qr/failed to resume session: failed to de-serialize session|ssl_session_(fetch|store)_by_lua_block:\d+: session id: [a-fA-F\d]+/s

--- grep_error_log_out eval
[
qr/^ssl_session_store_by_lua_block:5: session id: [a-fA-F\d]+$/s,
qr/^ssl_session_fetch_by_lua_block:4: session id: [a-fA-F\d]+
failed to resume session: failed to de-serialize session
ssl_session_store_by_lua_block:5: session id: [a-fA-F\d]+
$/s,
qr/ssl_session_fetch_by_lua_block:4: session id: [a-fA-F\d]+
failed to resume session: failed to de-serialize session
ssl_session_store_by_lua_block:5: session id: [a-fA-F\d]+
$/s,
]

--- no_error_log
[alert]
[emerg]
[error]



=== TEST 5: yield during doing handshake with client which uses low version OpenSSL
--- no_check_leak
--- http_config
    lua_shared_dict done 16k;
    lua_package_path "$TEST_NGINX_LUA_PACKAGE_PATH/?.lua;;";
    ssl_session_store_by_lua_block {
        local ssl = require "ngx.ssl.session"

        local sid = ssl.get_session_id()
        print("session id: ", sid)
    }

    ssl_session_fetch_by_lua_block {
        local ssl = require "ngx.ssl.session"

        ngx.sleep(0.01) -- yield

        local sid = ssl.get_session_id()
        print("session id: ", sid)
        local sess = "==garbage data=="
        local ok, err = ssl.set_serialized_session(sess)
        if not ok or err then
           print("failed to resume session: ", err)
        end
    }

    server {
        listen $TEST_NGINX_SERVER_SSL_PORT ssl;
        server_name test.com;
        ssl_session_tickets off;
        ssl_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;
        ssl_certificate_key $TEST_NGINX_CERT_DIR/cert/test.key;

        location / {
            content_by_lua_block {
                ngx.shared.done:set("handshake", true)
            }
        }
    }
--- config
    lua_ssl_trusted_certificate $TEST_NGINX_CERT_DIR/cert/test.crt;

    location /t {
        set $sess_file $TEST_NGINX_HTML_DIR/sess;
        set $addr 127.0.0.1:$TEST_NGINX_SERVER_SSL_PORT;
        content_by_lua_block {
            ngx.shared.done:delete("handshake")
            local addr = ngx.var.addr;
            local sess = ngx.var.sess_file
            local req = "'GET / HTTP/1.0\r\nHost: test.com\r\nConnection: close\r\n\r\n'"
            local f, err
            if not package.loaded.session then
                f, err = io.popen("echo -n " .. req .. " | timeout 3s openssl s_client -connect " .. addr .. " -sess_out " .. sess)
                package.loaded.session = true
            else
                f, err = io.popen("echo -n " .. req .. " | timeout 3s openssl s_client -connect " .. addr .. " -sess_in " .. sess)
            end

            if not f then
                ngx.say(err)
                return
            end

            local step = 0.001
            while step < 2 do
                ngx.sleep(step)
                step = step * 2

                if ngx.shared.done:get("handshake") then
                    local out = f:read('*a')
                    ngx.log(ngx.INFO, out)
                    ngx.say("ok")
                    f:close()
                    return
                end
            end

            ngx.log(ngx.ERR, "openssl client handshake timeout")
        }
    }

--- request
GET /t
--- response_body
ok
--- error_log eval
qr/content_by_lua\(nginx\.conf:\d+\):\d+: CONNECTED/
--- grep_error_log eval
qr/failed to resume session: failed to de-serialize session|ssl_session_(fetch|store)_by_lua_block:\d+: session id: [a-fA-F\d]+/s
--- grep_error_log_out eval
[
qr/^ssl_session_store_by_lua_block:\d+: session id: [a-fA-F\d]+$/s,
qr/^ssl_session_fetch_by_lua_block:\d+: session id: [a-fA-F\d]+
failed to resume session: failed to de-serialize session
ssl_session_store_by_lua_block:\d+: session id: [a-fA-F\d]+
$/s,
qr/ssl_session_fetch_by_lua_block:\d+: session id: [a-fA-F\d]+
failed to resume session: failed to de-serialize session
ssl_session_store_by_lua_block:\d+: session id: [a-fA-F\d]+
$/s,
]

--- no_error_log
[alert]
[emerg]
[error]