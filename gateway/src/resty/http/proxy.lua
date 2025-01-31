-- This module uses lua-resty-http and properly sets it up to use http(s) proxy.

local http = require 'resty.resolver.http'
local resty_url = require 'resty.url'
local resty_env = require 'resty.env'
local format = string.format

local _M = {

}

local function default_port(uri)
    return uri.port or resty_url.default_port(uri.scheme)
end

local function connect_direct(httpc, request)
    local uri = request.uri
    local host = uri.host
    local ip, port = httpc:resolve(host, nil, uri)
    -- #TODO: This logic may no longer be needed as of PR#1323 and should be reviewed as part of a refactor
    local options = { pool = format('%s:%s', host, port) }
    local ok, err = httpc:connect(ip, port or default_port(uri), options)

    if not ok then return nil, err end

    ngx.log(ngx.DEBUG, 'connection to ', host, ':', httpc.port, ' established',
        ', reused times: ', httpc:get_reused_times())

    if uri.scheme == 'https' then
        ok, err = httpc:ssl_handshake(nil, host, request.ssl_verify)
        if not ok then return nil, err end
    end

    -- use correct host header
    httpc.host = host

    return httpc
end

local function _connect_tls_direct(httpc, request, host, port)

    local uri = request.uri

    local ok, err = httpc:ssl_handshake(nil, uri.host, request.ssl_verify)
    if not ok then return nil, err end

    return httpc
end

local function _connect_proxy_https(httpc, request, host, port)
    -- When the connection is reused the tunnel is already established, so
    -- the second CONNECT request would reach the upstream instead of the proxy.
    if httpc:get_reused_times() > 0 then
        return httpc, 'already connected'
    end

    local uri = request.uri

    local res, err = httpc:request({
        method = 'CONNECT',
        path = format('%s:%s', host, port or default_port(uri)),
        headers = {
            ['Host'] = request.headers.host or format('%s:%s', uri.host, default_port(uri)),
            ['Proxy-Authorization'] = request.proxy_auth or ''
        }
    })
    if not res then return nil, err end

    if res.status < 200 or res.status > 299 then
        return nil, "failed to establish a tunnel through a proxy: " .. res.status
    end

    res, err = httpc:ssl_handshake(nil, uri.host, request.ssl_verify)
    if not res then return nil, err end

    return httpc
end

local function connect_proxy(httpc, request, skip_https_connect)
    -- target server requires hostname not IP and DNS resolution is left to the proxy itself as specified in the RFC #7231
    -- https://httpwg.org/specs/rfc7231.html#CONNECT
    local uri = request.uri
    local proxy_uri = request.proxy

    if proxy_uri.scheme ~= 'http' then
        return nil, 'proxy connection supports only http'
    else
        proxy_uri.port = default_port(proxy_uri)
    end

    local port = default_port(uri)

    -- TLS tunnel is verified only once, so we need to reuse connections only for the same Host header
    local options = { pool = format('%s:%s:%s:%s', proxy_uri.host, proxy_uri.port, uri.host, port) }
    local ok, err = httpc:connect(proxy_uri.host, proxy_uri.port, options)
    if not ok then return nil, err end

    ngx.log(ngx.DEBUG, 'connection to ', proxy_uri.host, ':', proxy_uri.port, ' established',
        ', pool: ', options.pool, ' reused times: ', httpc:get_reused_times())

    ngx.log(ngx.DEBUG, 'targeting server ', uri.host, ':', uri.port)

    if uri.scheme == 'http' then
        -- http proxy needs absolute URL as the request path
        request.path = format('%s://%s:%s%s', uri.scheme, uri.host, uri.port, uri.path or '/')
        return httpc
    elseif uri.scheme == 'https' and skip_https_connect then
        request.path = format('%s://%s:%s%s', uri.scheme, uri.host, uri.port, request.path or '/')
        return _connect_tls_direct(httpc, request, uri.host, uri.port)
    elseif uri.scheme == 'https' then
        return _connect_proxy_https(httpc, request, uri.host, uri.port)

    else
        return nil, 'invalid scheme'
    end
end

local function parse_request_uri(request)
    local uri = request.uri or resty_url.parse(request.url)
    request.uri = uri
    return uri
end

local function find_proxy_url(request)
    local uri = parse_request_uri(request)
    if not uri then return end

    -- request can have a local proxy defined and env variables have lower
    -- priority, if the proxy is defined in the request that will be used.
    return request.proxy_uri or _M.find(uri)
end

local function connect(request, skip_https_connect)
    local httpc = http.new()
    local proxy_uri = find_proxy_url(request)

    request.ssl_verify = request.options and request.options.ssl and request.options.ssl.verify
    request.proxy = proxy_uri

    if proxy_uri then
        return connect_proxy(httpc, request, skip_https_connect)
    else
        return connect_direct(httpc, request)
    end
end

function _M.env()
    local all_proxy = resty_env.value('all_proxy') or resty_env.value('ALL_PROXY')

    return {
        http_proxy = resty_env.value('http_proxy') or resty_env.value('HTTP_PROXY') or all_proxy,
        https_proxy = resty_env.value('https_proxy') or resty_env.value('HTTPS_PROXY') or all_proxy,
        no_proxy = resty_env.value('no_proxy') or resty_env.value('NO_PROXY'),
    }
end

local options

function _M.options() return options end

function _M.active(request)
    return not not find_proxy_url(request)
end

function _M.find(uri)
    local proxy_url = http:get_proxy_uri(uri.scheme, uri.host)

    if proxy_url then
        return resty_url.parse(proxy_url)
    else
        return nil, 'no_proxy'
    end
end

function _M:reset(opts)
    options = opts or self.env()

    http:set_proxy_options(options)

    return self
end

_M.new = connect

return _M:reset()
