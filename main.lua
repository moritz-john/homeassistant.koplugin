--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

-- Use debug_config.lua if it exists (for development); otherwise config.lua (for end-user)
local ok, ha_config = pcall(require, "debug_config")
if not ok then
    ha_config = require("config")
end

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local json = require("json")

local HomeAssistant = WidgetContainer:extend {
    name = "homeassistant",
    is_doc_only = false,
}

--- Initialize the plugin
function HomeAssistant:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

--- Register dispatcher actions for each Home Assistant entity
-- This allows entities to be triggered via gestures
function HomeAssistant:onDispatcherRegisterActions()
    for i, entity in ipairs(ha_config.entities) do
        local action_id = string.format("ha_entity_%d", i)

        Dispatcher:registerAction(action_id, {
            category = "none",
            event = "ActivateHAEvent",
            arg = entity,
            title = entity.label,
            general = true,
            separator = (i == #ha_config.entities), -- add separator after last entity
        })
    end
end

--- Add Home Assistant submenu to the Tools menu
-- Creates a menu item for each configured entity
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

    for _, entity in ipairs(ha_config.entities) do
        table.insert(sub_items, {
            text = entity.label,
            callback = function()
                self:onActivateHAEvent(entity)
            end,
        })
    end

    menu_items.homeassistant = {
        text = _("Home Assistant"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

--- Extract domain & action from or entity.acion
function HomeAssistant:getDomainandAction(entity)
    local domain, action
    if entity.action then
        domain, action = entity.action:match("^([^.]+)%.(.+)$")
        return domain, action
    else
        domain = entity.target:match("^([^.]+)")
        return domain
    end
end

--- TODO: currently not in use
-- function HomeAssistant:stringifyTarget(target)
--     if type(target) == "table" then
--         return table.concat(target, ", ")
--     else
--         return tostring(target or "N/A")
--     end
-- end

--- Handle ActivateHAEvent
-- Flow: "POST"|"GET" -> prepareRequest -> performRequest -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local method = entity.action and "POST" or "GET"

    -- Prepare (and perform) the request
    local code, response = self:prepareRequest(entity, method)

    -- Build message text based on result
    local messageText, timeout = self:buildMessage(entity, code, response, method)

    -- Show message box
    UIManager:show(InfoMessage:new {
        text = messageText,
        timeout = timeout,
        icon = "homeassistant",
    })
end

--- Prepare HTTP request for Home Assistant API
-- POST requests call services (e.g., turn_on, turn_off)
-- GET requests retrieve entity state
function HomeAssistant:prepareRequest(entity, method)
    local url, request_body

    if method == "POST" then
        -- Call a service (e.g., light.turn_on, switch.toggle)
        local domain, action = self:getDomainandAction(entity)

        url = string.format("http://%s:%d/api/services/%s/%s",
            ha_config.host, ha_config.port, domain, action)

        local build_request_body = { entity_id = entity.target }

        if entity.data then
            for k, v in pairs(entity.data) do
                build_request_body[k] = v
            end
        end

        request_body = json.encode(build_request_body)
    else
        -- Query entity state
        url = string.format("http://%s:%d/api/states/%s",
            ha_config.host, ha_config.port, entity.target)

        request_body = nil
    end

    -- Perform the request and return code, response
    return self:performRequest(url, method, request_body)
end

--- Send a REST API request to the Home Assistant API
function HomeAssistant:performRequest(url, method, request_body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    http.TIMEOUT = 6

    local headers = {
        ["Authorization"] = "Bearer " .. ha_config.token,
    }
    local source
    local response_body = {}

    -- Only POST requests include a request body
    if request_body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#request_body)
        source = ltn12.source.string(request_body)
    end

    local res, code = http.request {
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(response_body)
    }

    return code, table.concat(response_body)
end

--- Build user-facing message based on API response
-- TODO: decide if message should include  "Entity ID" (-> requires funtion stringifyTarget)
function HomeAssistant:buildMessage(entity, code, response, method)
    -- on Error:
    if code ~= 200 and code ~= 201 then
        return string.format(_(
                "- - Error - -\n" ..
                "Label: %s\n" ..
                "Domain: %s\n" ..
                "Service: %s\n" ..
                "Response: %s"),
            entity.label, self:getDomainandAction(entity), entity.action or "N/A", tostring(code)
        ), nil
    end
    -- on Success:
    if method == "POST" then
        return string.format(_(
                "- - Success - -\n" ..
                "❯ %s\n" ..
                "Domain: %s\n" ..
                "Action: %s"),
            entity.label, self:getDomainandAction(entity), entity.action
        ), 5
    else
        local state = json.decode(response)
        return string.format(_(
                "- - Info - -\n" ..
                "%s\n" ..
                "Domain: %s\n" ..
                "❯ State: %s\n"),
            entity.label, self:getDomainandAction(entity), state.state or "unknown"
        ), nil
    end
end

return HomeAssistant
