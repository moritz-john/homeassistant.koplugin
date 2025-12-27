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
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local json = require("json")

--- InfoMessage Icon Check
--- If '/icons/homeassistant.svg' exists, use it as icon in InfoMessage
local icon_path = DataStorage:getDataDir() .. "/icons/homeassistant.svg"
local file_mode = lfs.attributes(icon_path, "mode")
local icon_value = nil

if file_mode == "file" then
    icon_value = "homeassistant"
end

--- Font Glyph definitions
-- Reference font: koreader/fonts/nerdfonts/symbols.ttf
local Glyphs = {
    ha = "\u{EECE}",
    -- download_network = "\u{EDF2}",
    -- help_network = "\u{EDF3}",
    -- upload_network = "\u{EDF4}",
}

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
        text = _(Glyphs.ha .. " Home Assistant"),
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

        -- Add return_response query parameter if needed
        local query_params = ""
        if entity.response_variable then
            query_params = "?return_response=true"
        end

        url = string.format("http://%s:%d/api/services/%s/%s%s",
            ha_config.host, ha_config.port, domain, action, query_params)

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
        -- with Response Data:
    elseif entity.response_variable and method == "POST" then
        messageText, timeout = self:buildResponseDataMessage(entity, response)
    elseif method == "POST" then
        -- Action/"POST":
        messageText, timeout = self:buildActionMessage(entity)
    else
        -- State/"GET":
        messageText, timeout = self:buildStateMessage(entity, response)
    end

    -- Show message box
    UIManager:show(InfoMessage:new {
        text = messageText,
        timeout = timeout,
        icon = icon_value,
    })
end

--- Build error message
function HomeAssistant:buildErrorMessage(entity, code)
    return string.format(_(
            "𝙀𝙧𝙧𝙤𝙧_:\n" ..
            "label: %s\n" ..
            "domain: %s\n" ..
            "action: %s\n" ..
            "response: %s"),
        entity.label, self:getDomainandAction(entity), entity.action or "n/a", tostring(code)
    ), nil
end

--- Build success message for actions / POST requests
function HomeAssistant:buildActionMessage(entity)
    return string.format(_(
            "𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘢𝘤𝘵𝘪𝘰𝘯_:\n" ..
            "%s\n\n" ..
            "domain: %s\n" ..
            "action: %s"),
        entity.label, self:getDomainandAction(entity), entity.action
    ), 5
end

--- Build success message for state / GET requests
function HomeAssistant:buildStateMessage(entity, response)
    -- Build the base message
    local base_message = string.format(_(
            "𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘴𝘵𝘢𝘵𝘦_:\n" ..
            "%s\n\n"),
        entity.label
    )

    -- If no attributes are configured in config.lua, show helper text
    if not entity.attributes then
        return base_message .. "Add attributes to this entity in `config.lua`.\n", nil
    end

    -- Parse the response
    local state = json.decode(response)

    -- Ensure attributes is a table (convert single string if needed)
    local attributes = entity.attributes
    if type(attributes) == "string" then
        attributes = { attributes }
    end

    -- Iterate and extract each configured attribute value
    local attribute_message = ""
    for _, attribute_name in ipairs(attributes) do
        -- Access attribute: state property (e.g., 'state', 'last_changed') or state attribute
        local attribute_value = state[attribute_name]
            or (state.attributes and state.attributes[attribute_name])

        -- Handle attribute value formatting
        local value = self:formatAttributeValue(attribute_value)
        attribute_message = attribute_message .. string.format("%s: %s\n", attribute_name, value)
    end

    local full_message = base_message .. attribute_message
    return full_message, nil
end

-- Helper function to format any state attribute value into a string
function HomeAssistant:formatAttributeValue(value)
    local value_type = type(value)

    if value == nil or value_type == "function" then
        -- Handle non-existent, malformed or JSON decode errors (e.g. state.attributes.color_mode when a light is turned off)
        return "null"
    elseif type(value) == "table" then
        -- Handle simple arrays/tables (e.g., [255, 204, 0])
        local parts = {}
        for _, v in ipairs(value) do
            table.insert(parts, tostring(v))
        end
        return table.concat(parts, ", ")
    else
        -- Handle strings, numbers, booleans, etc.
        return tostring(value)
    end
end

--- Build message for responses with response_variable
function HomeAssistant:buildResponseDataMessage(entity, response)
    -- Build the base message
    local base_message = string.format(_(
            "𝘙𝘦𝘴𝘱𝘰𝘯𝘴𝘦_:\n" ..
            "%s\n\n"),
        entity.label
    )

    local full_message = ""

    -- Handle different kind of actions which use "?return_response"
    if entity.action == "todo.get_items" then
        full_message = base_message .. self:formatTodoItems(response)
    else
        -- TODO: Add response data support for other entity types
        -- Fallback for unknown action types
        full_message = base_message .. "Only 'todo.get_items' is supported for now.\n"
    end

    return full_message, nil
end

--- Format todo list items
function HomeAssistant:formatTodoItems(response)
    -- Decode the response body
    local response_data = json.decode(response)
    local service_response = response_data.service_response
    local todo_message = ""

    -- service_response is a map where:
    --   keys = entity IDs (e.g., "todo.shopping_list")
    --   values = objects containing an "items" array
    for _, entity in pairs(service_response) do
        local items = entity.items

        -- Validate that items is a table
        if type(items) == "table" then
            -- Handle empty list
            if #items == 0 then
                return "Todo list is empty\n"
            end

            -- Convert each todo item into "Summary: [x]" or "Summary: [ ]" format
            for _, item in ipairs(items) do
                local is_completed = (item.status == "completed")
                local checkbox = is_completed and "[x]" or "[ ]"

                todo_message = todo_message .. string.format("%s %s\n", checkbox, tostring(item.summary))
            end

            -- Stop after the first entity's items are processed
            break
        end
    end

    return todo_message
end

return HomeAssistant
