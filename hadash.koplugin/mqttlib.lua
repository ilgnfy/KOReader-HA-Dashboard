-- Entry point for the vendored luamqtt library (mqtt/ subdirectory).
-- A bare `require("mqtt")` does NOT resolve to mqtt/init.lua under a
-- KOReader plugin's own directory -- its package.path only adds a flat
-- `plugins/hadash.koplugin/?.lua` template for this plugin, not a
-- `?/init.lua` one (confirmed from the exact search list in a failed
-- `require("mqtt")` error). Dotted requires like `require("mqtt.client")`
-- DO resolve correctly into the subdirectory via that same `?.lua`
-- template (dot becomes slash), which is what mqtt/init.lua and every
-- other vendored file use internally -- so this flat file, a copy of
-- mqtt/init.lua's own logic, is the only piece that needed moving.
-- Original: https://github.com/xHasKx/luamqtt (MIT).

local mqtt = {}

local const = require("mqtt.const")
for key, value in pairs(const) do
    mqtt[key] = value
end

local type = type
local select = select
local require = require

local client = require("mqtt.client")
local client_create = client.create

local ioloop_get = require("mqtt.ioloop").get

function mqtt.client(...)
    return client_create(...)
end

mqtt.get_ioloop = ioloop_get

function mqtt.run_ioloop(...)
    local loop = ioloop_get()
    for i = 1, select("#", ...) do
        local cl = select(i, ...)
        loop:add(cl)
        if type(cl) ~= "function" then
            cl:start_connecting()
        end
    end
    return loop:run_until_clients()
end

function mqtt.run_sync(cl)
    local ok, err = cl:start_connecting()
    if not ok then
        return false, err
    end
    while cl.connection do
        ok, err = cl:_sync_iteration()
        if not ok then
            return false, err
        end
    end
end

return mqtt
