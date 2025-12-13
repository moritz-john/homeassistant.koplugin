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

--- Extract domain & action from entity.target or entity.action
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
-- Flow: build URL & body -> performRequest -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local url, request_body, method

    if entity.action then
        -- POST: Call a service (e.g., light.turn_on, switch.toggle)
        method = "POST"
        local domain, action = self:getDomainandAction(entity)

        url = string.format("http://%s:%d/api/services/%s/%s",
            ha_config.host, ha_config.port, domain, action)

        -- START: Build request_body
        local build_request_body = {}

        -- Handle entity.target: can be string, array, or complex object
        if type(entity.target) == "string" then
            -- Simple string: target = "light.foo"
            -- Becomes: { entity_id = "light.foo" }
            build_request_body.entity_id = entity.target
        elseif type(entity.target) == "table" then
            -- Table needs to distinguish between array and key-value map
            -- In Lua, arrays have numeric indices and length > 0
            local is_array = (#entity.target > 0)

            if is_array then
                -- Array of entity IDs: target = { "light.foo", "light.bar" }
                -- Becomes: { entity_id = { "light.foo", "light.bar" } }
                build_request_body.entity_id = entity.target
            else
                -- Object format: target = { entity_id = {...} } or { area_id = "flur" }
                -- Copy all keys directly (supports entity_id, area_id, device_id, label_id)
                -- Note: Do not mix multiple target types (e.g., entity_id + area_id)
                for k, v in pairs(entity.target) do
                    build_request_body[k] = v
                end
            end
        end

        -- Add additional Home Assistant data attributes to the service call
        if entity.data then
            for k, v in pairs(entity.data) do
                build_request_body[k] = v
            end
        end

        request_body = json.encode(build_request_body)
        -- END: Build request_body
    else
        -- GET: Query entity state
        method = "GET"
        url = string.format("http://%s:%d/api/states/%s",
            ha_config.host, ha_config.port, entity.target)

        request_body = nil
    end

    -- Perform the request
    local code, response = self:performRequest(url, method, request_body)

    -- Build and show message
    self:buildMessage(entity, code, response, method)
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
function HomeAssistant:buildMessage(entity, code, response, method)
    local messageText, timeout

    -- on Error:
    if code ~= 200 and code ~= 201 then
        messageText, timeout = self:buildErrorMessage(entity, code)
        -- on Success:
    elseif method == "POST" then
        -- "POST":
        messageText, timeout = self:buildSuccessPostMessage(entity)
    else
        -- "GET":
        messageText, timeout = self:buildSuccessGetMessage(entity, response)
    end

    -- Show message box
    UIManager:show(InfoMessage:new {
        text = messageText,
        timeout = timeout,
        icon = "homeassistant",
    })
end

--- Build error message
function HomeAssistant:buildErrorMessage(entity, code)
    return string.format(_(
            "𝙀𝙧𝙧𝙤𝙧\n" ..
            "label: %s\n" ..
            "domain: %s\n" ..
            "action: %s\n" ..
            "response: %s"),
        entity.label, self:getDomainandAction(entity), entity.action or "n/a", tostring(code)
    ), nil
end

--- Build success message for POST requests
function HomeAssistant:buildSuccessPostMessage(entity)
    return string.format(_(
            "𝘗𝘖𝘚𝘛 𝘙𝘦𝘲𝘶𝘦𝘴𝘵\n" ..
            "⏵ %s\n\n" ..
            "domain: %s\n" ..
            "action: %s"),
        entity.label, self:getDomainandAction(entity), entity.action
    ), 5
end

--- Build success message for GET requests
function HomeAssistant:buildSuccessGetMessage(entity, response)
    -- Build the base message
    local message = string.format(_(
            "𝘎𝘌𝘛 𝘙𝘦𝘲𝘶𝘦𝘴𝘵\n" ..
            "⏵ %s\n\n"),
        entity.label
    )

    -- Pass the raw response string to the attribute builder
    message = message .. self:buildAttributeMessage(response, entity)

    return message, nil
end

--- Build attribute message string from decoded state and entity config
function HomeAssistant:buildAttributeMessage(response, entity)
    local state = json.decode(response)
    local attribute_message = ""

    -- Check if entity.attributes are defined in config
    if entity.attributes then
        -- Make sure attribute_list is always a list
        local attribute_list = entity.attributes
        if type(attribute_list) == "string" then
            attribute_list = { attribute_list } -- Convert single string to list
        end

        for _, attribute_name in ipairs(attribute_list) do
            local attribute_value

            -- Check if it's a top-level state property first
            -- this allows us to access e.g. state.last_changed or state.last_updated
            if state[attribute_name] then
                attribute_value = state[attribute_name]
                -- Otherwise check in state.attributes
            elseif state.attributes then
                attribute_value = state.attributes[attribute_name]
            else
                attribute_value = nil
            end

            -- Handle different types of attribute values
            local value_string
            if attribute_value == nil then
                -- Handle attribute that don't exist in response
                value_string = "null"
            elseif type(attribute_value) == "boolean" then
                -- Handle booleans
                value_string = attribute_value and "true" or "false"
            elseif type(attribute_value) == "function" then
                -- Handle malformed responses or JSON decode errors (e.g. state.attributes.color_mode when a light is turned off)
                value_string = "null"
            elseif type(attribute_value) == "table" then
                -- Handle simple arrays or complex nested structures
                local is_simple = true
                for _, v in ipairs(attribute_value) do
                    if type(v) == "table" then
                        is_simple = false
                        break
                    end
                end

                if is_simple then
                    -- Simple array like [255, 204, 0]
                    local parts = {}
                    for _, v in ipairs(attribute_value) do
                        table.insert(parts, tostring(v))
                    end
                    value_string = table.concat(parts, ", ")
                else
                    -- Complex nested structure
                    value_string = string.format("[%d items]", #attribute_value)
                end
            else
                -- Handle strings, numbers, and any other types
                value_string = tostring(attribute_value)
            end
            attribute_message = attribute_message .. string.format("%s: %s\n", attribute_name, value_string)
        end
    else
        -- No attributes configured, append the placeholder line
        attribute_message = attribute_message .. "Add attributes to this entity in `config.lua`.\n"
    end

    return attribute_message
end

return HomeAssistant
