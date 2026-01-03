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
local rapidjson = require("rapidjson")

--- InfoMessage Icon Check
-- If '/icons/homeassistant.svg' exists, use it as icon in InfoMessage
local icon_path = DataStorage:getDataDir() .. "/icons/homeassistant.svg"
local file_mode = lfs.attributes(icon_path, "mode")
local icon_value = nil

if file_mode == "file" then
    icon_value = "homeassistant"
end

--- Font glyph definitions
-- Reference font: koreader/fonts/nerdfonts/symbols.ttf
local Glyphs = {
    ha = "\u{EECE}",
    checkbox_blank = "\u{E830}",
    checkbox_marked = "\u{E834}",
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
        return domain, nil
    end
end

--- Helper to build the JSON body for the request
function HomeAssistant:buildServiceData(entity)
    local body = {}

    -- Check if target is a List (Array)
    -- #table > 0 as check for a list of items
    local is_list = (type(entity.target) == "table" and #entity.target > 0)

    -- Case 1: String or List -> Assign to 'entity_id'
    -- e.g. "light.foo" or { "light.a", "light.b" }
    if type(entity.target) == "string" or is_list then
        body.entity_id = entity.target

        -- Case 2: Map (Key-Value) -> Merge into body
        -- e.g. { entity_id = { "light.foo", "light.bar" } } or { area_id = "flur" }
    elseif type(entity.target) == "table" then
        for k, v in pairs(entity.target) do
            body[k] = v
        end
    end

    -- Merge additional 'data' attributes if present
    if entity.data then
        for k, v in pairs(entity.data) do
            body[k] = v
        end
    end

    return body
end

--- Handle ActivateHAEvent
-- Flow: build URL & body -> performRequest -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local url, service_data, method

    if entity.action then
        -- POST: Call a service (e.g., light.turn_on, switch.toggle)
        method = "POST"
        local domain, action = self:getDomainandAction(entity)
        local query_params = entity.response_data and "?return_response=true" or ""
        url = string.format("http://%s:%d/api/services/%s/%s%s",
            ha_config.host, ha_config.port, domain, action, query_params)
        service_data = self:buildServiceData(entity)
    else
        -- GET: Query entity state
        method = "GET"
        url = string.format("http://%s:%d/api/states/%s",
            ha_config.host, ha_config.port, entity.target)
    end

    -- Perform the request
    local error, response_data = self:performRequest(url, method, service_data)

    -- Build and show message
    self:buildMessage(entity, method, error, response_data)
end

--- Executes a REST request to Home Assistant
function HomeAssistant:performRequest(url, method, service_data)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    http.TIMEOUT = 6

    local request_body = service_data and rapidjson.encode(service_data) or nil

    -- Only POST requests include service_data
    local headers = {
        ["Authorization"] = "Bearer " .. ha_config.token,
        ["Content-Type"] = service_data and "application/json" or nil,
        ["Content-Length"] = service_data and tostring(#request_body) or nil
    }

    local response_body = {}

    -- result, status code, headers, status line
    local result, code, __, __ = http.request {
        url = url,
        method = method,
        headers = headers,
        source = service_data and ltn12.source.string(request_body) or nil,
        sink = ltn12.sink.table(response_body)
    }

    -- Error handling
    if result == nil or (code ~= 200 and code ~= 201) then
        return true, code
    end

    -- Decode json response when required
    local raw_response = table.concat(response_body)
    local response_data = nil

    if raw_response ~= "" then
        local success, decoded = pcall(rapidjson.decode, raw_response)
        response_data = success and decoded or nil
    else
        -- Handle JSON Decode Error
        return true, "JSON Decode Failed"
    end

    return false, response_data
end

--- Build user-facing message based on API response
function HomeAssistant:buildMessage(entity, method, error, response_data)
    local messageText, timeout

    -- on Error:
    if error == true then
        messageText, timeout = self:buildErrorMessage(entity, response_data)
        -- on Success:
        -- with Response Data:
    elseif entity.response_data and method == "POST" then
        messageText, timeout = self:buildResponseDataMessage(entity, response_data)
    elseif method == "POST" then
        -- Action/"POST":
        messageText, timeout = self:buildActionMessage(entity)
    else
        -- State/"GET":
        messageText, timeout = self:buildStateMessage(entity, response_data)
    end

    -- Show message box
    UIManager:show(InfoMessage:new {
        text = messageText,
        timeout = timeout,
        icon = icon_value,
    })
end

--- Build error message
function HomeAssistant:buildErrorMessage(entity, response_data)
    return string.format(_(
            "𝙀𝙧𝙧𝙤𝙧\n" ..
            "%s\n\n" ..
            "⏵ response:\n" ..
            "%s"),
        entity.label,
        response_data
    ), nil
end

--- Build success message for actions / POST requests
function HomeAssistant:buildActionMessage(entity)
    return string.format(_(
            "𝘗𝘦𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯\n" ..
            "%s\n\n" ..
            "action: %s"),
        entity.label,
        entity.action
    ), 5
end

--- Build success message for state / GET requests
function HomeAssistant:buildStateMessage(entity, response_data)
    -- Build the base message
    local base_message = string.format(_(
            "𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦\n" ..
            "%s\n\n"),
        entity.label
    )

    -- If no attributes are configured in config.lua, show helper text
    if not entity.attributes then
        return base_message .. "Add attributes to this entity in `config.lua`.\n", nil
    end

    -- Named "state", so that later processing matches Home Assistant state object naming
    local state = response_data

    -- Ensure attribute(s) in config.lua are a table (convert single string if needed)
    local attributes = entity.attributes
    if type(attributes) == "string" then
        attributes = { attributes }
    end

    local attribute_message = ""

    -- Iterate through user-configured attribute names from config.lua and match against API response
    for _, name in ipairs(attributes) do
        -- First check state[attribute_name] (e.g., state.state, state.last_changed)
        -- Then check state.attributes[attribute_name] (e.g., state.attributes.brightness)
        local attribute_value = state[name]
            or (state.attributes and state.attributes[name])

        -- Handle attribute value formatting
        local value = self:formatAttributeValue(attribute_value)
        attribute_message = attribute_message .. string.format("%s: %s\n", name, value)
    end

    local full_message = base_message .. attribute_message
    return full_message, nil
end

-- Helper function to format any state attribute value into a string
function HomeAssistant:formatAttributeValue(value)
    local value_type = type(value)

    if value == rapidjson.null then
        -- Handle non-existent, malformed or JSON decode errors
        return "null"
    elseif value_type == "table" then
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

--- Build success message for actions with response_data
function HomeAssistant:buildResponseDataMessage(entity, response_data)
    -- Build the base message
    local base_message = string.format(_(
            "𝘙𝘦𝘴𝘱𝘰𝘯𝘴𝘦 𝘋𝘢𝘵𝘢\n" ..
            "%s\n\n"),
        entity.label
    )

    local full_message = ""

    -- Handle different kind of actions which use "?return_response"
    if entity.action == "todo.get_items" then
        full_message = base_message .. self:formatTodoItems(response_data)
    else
        -- TODO: Add response data support for other entity types
        -- Fallback message
        full_message = base_message .. "Configuration error.\nCheck the documentation 'Response Data' section.\n"
    end

    return full_message, nil
end

--- Format todo list items
function HomeAssistant:formatTodoItems(response_data)
    local service_response = response_data.service_response
    local todo_message = ""

    -- Iterate over service_response (key: entity_id -> value: todo_response)
    -- We are using a for loop instead of 'local items = service_response[entity.target].items'
    -- Because we might want to show more than one To-do list in the future
    -- Currently we break the loop after the first target/entity_id
    for _, todo_response in pairs(service_response) do
        local items = todo_response.items

        -- Validate that items is a table
        if type(items) == "table" then
            -- Handle empty list
            if #items == 0 then
                return "Todo list is empty\n"
            end

            -- PASS 1: Add only the active (non-completed) items first
            for _, item in ipairs(items) do
                if item.status == "needs_action" then
                    todo_message = todo_message ..
                        string.format("%s %s\n", Glyphs.checkbox_blank, tostring(item.summary))
                end
            end

            -- PASS 2: Add only the completed items at the bottom
            for _, item in ipairs(items) do
                if item.status == "completed" then
                    todo_message = todo_message ..
                        string.format("%s %s\n", Glyphs.checkbox_marked, tostring(item.summary))
                end
            end

            -- Stop after the first entity's items are processed
            break
        end
    end

    return todo_message
end

return HomeAssistant
