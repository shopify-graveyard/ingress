local util = require('util')
local split = require('util.split')
local ngx_upstream = require("ngx.upstream")
local implementations = require('balancer.implementations')

local static_backends = {}
local static_balancers = {}

local DEFAULT_LB_ALG = "ewma"

local _M = {}

local function marshal_endpoint(endpoint)
    if (not endpoint.address) or (not endpoint.port) then
        if endpoint.addr then
            local addr, err = split.parse_addr(endpoint.addr)
            if err then
                return nil, err
            end

            endpoint.address = addr.host
            endpoint.port = addr.port
            endpoint.addr = nil

            return endpoint, nil
        end
    end
    return nil, "error in grabbing address & port" 
end

local function create_static_backend(upstream_name)
    local sb = {
        name = upstream_name,
        endpoints = {},
        ['load-balance'] = DEFAULT_LB_ALG
    }

    local servers = ngx_upstream.get_servers(upstream_name)
    for _, server in ipairs(servers) do
        local endpoint = marshal_endpoint(server)
        table.insert(sb.endpoints, endpoint)
    end

    return sb
end

local function populate_static_backends()
    local upstreams = ngx_upstream.get_upstreams()
    for _, upstream_name in ipairs(upstreams) do
        if upstream_name ~= "upstream_balancer" then
            local sb = create_static_backend(upstream_name)
            static_backends[upstream_name] = sb
        end
    end
end

local function populate_static_balancers()
    for _, backend in pairs(static_backends) do
        local implementation = implementations.get(backend)
        static_balancers[backend.name] = implementation:new(backend)
    end
end

function _M.configure()
    populate_static_backends()
    populate_static_balancers()
end

function _M.get()
    return static_balancers
end

if _TEST then
    _M.backends = function()
        return static_backends
    end

    _M.reset = function()
        static_backends = {}
        static_balancers = {}
    end
end

return _M
