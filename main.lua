--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")

-- Use debug_config.lua if it exists (for development); otherwise config.lua (for end-user)
local ok, ha_config = pcall(require, "debug_config")
if not ok then
    ha_config = require("config")
end

--- InfoMessage Icon Check
-- If '/icons/homeassistant.svg' exists, use it as icon in InfoMessage
local icon_path = DataStorage:getDataDir() .. "/icons/homeassistant.svg"
local file_mode = lfs.attributes(icon_path, "mode")
local icon_value = nil

if file_mode == "file" then
    icon_value = "homeassistant"
end

--- Define font glyphs
-- Reference font: koreader/fonts/nerdfonts/symbols.ttf
local Glyphs = {
    ha = "\u{EECE}",
    checkbox_blank = "\u{E830}",
    checkbox_marked = "\u{E834}",
    calendar_clock = "\u{E7EF}",
    weather = "\u{EC94}",
    thermometer = "\u{E20A}",
    umbrella = "\u{E220}",
    wind_speed = "\u{EC9C}"
}

--- Define Home Assisant base_url
local protocol = ha_config.https == true and "https" or "http"
local base_url = string.format("%s://%s:%d", protocol, ha_config.host, ha_config.port)

local HomeAssistant = WidgetContainer:extend {
    name                     = "homeassistant",
    is_doc_only              = false,
    -- timeout values in seconds
    HTTP_TIMEOUT             = 6,
    SIMPLE_MESSAGE_TIMEOUT   = 5,
    RESPONSE_MESSAGE_TIMEOUT = nil,
    ERROR_MESSAGE_TIMEOUT    = nil,
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

--- Handle ActivateHAEvent
-- Flow: determine endpoint -> call API method -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local error, response_data

    if entity.action then
        error, response_data = self:apiServices(entity)
    elseif entity.template then
        error, response_data = self:apiTemplate(entity)
    elseif entity.attributes then
        error, response_data = self:apiStates(entity)
    else
        self:buildMessage(entity, true, "Invalid 'config.lua':\nmissing required fields")
        return
    end

    self:buildMessage(entity, error, response_data)
end

--- Trim leading and trailing whitespace from each line of a multi-line string
-- This ensures that indented Lua long-strings ( template = [[ ... ]]) are sent to 
-- Home Assistant without the extra indentation/whitespace from config.lua
function HomeAssistant:trimWhitespace(str)
    local lines = {}
    for line in str:gmatch("[^\n]+") do
        table.insert(lines, line:match("^%s*(.-)%s*$"))
    end
    return table.concat(lines, "\n")
end

--- POST /api/services/<domain>/<service> - Call a Home Assistant service
-- Handle actions with and without action response data
function HomeAssistant:apiServices(entity)
    local domain, action = entity.action:match("^([^.]+)%.(.+)$")
    local response_parameter = entity.response_data == true and "?return_response=true" or ""
    local url = string.format("%s/api/services/%s/%s%s",
        base_url, domain, action, response_parameter)

    -- If response_data is enabled, only allow string targets
    if entity.response_data == true and type(entity.target) ~= "string" then
        return true, "Invalid 'config.lua':\nActions with response data only allow a single target (as string)"
    end

    -- Build the JSON body for the service call
    local service_data = {}

    -- Check if target is a List (Array)
    -- #table > 0 as check for a list of items
    local is_list = (type(entity.target) == "table" and #entity.target > 0)

    -- Case 1: String or List -> Assign to 'entity_id'
    -- e.g. "light.foo" or { "light.a", "light.b" }
    if type(entity.target) == "string" or is_list then
        service_data.entity_id = entity.target

        -- Case 2: Map (Key-Value) -> Merge into body
        -- e.g. { entity_id = { "light.foo", "light.bar" } } or { area_id = "flur" }
    elseif type(entity.target) == "table" then
        for k, v in pairs(entity.target) do
            service_data[k] = v
        end
    end

    -- Merge additional 'data' attributes if present
    if entity.data then
        for k, v in pairs(entity.data) do
            service_data[k] = v
        end
    end

    local error, response_data = self:performRequest(entity, url, "POST", service_data)
    return error, response_data
end

--- POST /api/template - Evaluate a Home Assistant template
function HomeAssistant:apiTemplate(entity)
    local url = string.format("%s/api/template", base_url)
    local service_data = { template = self:trimWhitespace(entity.template) }

    local error, response_data = self:performRequest(entity, url, "POST", service_data)
    return error, response_data
end

--- GET /api/states/<entity_id> - Fetch entity state from Home Assistant
function HomeAssistant:apiStates(entity)
    local url = string.format("%s/api/states/%s", base_url, entity.target)

    local error, response_data = self:performRequest(entity, url, "GET", nil)
    return error, response_data
end

--- Executes a REST request to Home Assistant
-- Only POST requests include service_data / request_body / source
function HomeAssistant:performRequest(entity, url, method, service_data)
    http.TIMEOUT = self.HTTP_TIMEOUT

    local request_body = service_data and rapidjson.encode(service_data) or nil

    local headers = {
        ["Authorization"] = "Bearer " .. ha_config.token,
        ["Content-Type"] = service_data and "application/json" or nil,
        ["Content-Length"] = service_data and tostring(#request_body) or nil
    }

    local response_body = {}

    -- result, status code, headers, status line
    local result, code = http.request {
        url = url,
        method = method,
        headers = headers,
        source = service_data and ltn12.source.string(request_body) or nil,
        sink = ltn12.sink.table(response_body)
    }

    local raw_response = table.concat(response_body)

    -- Error Handling
    if result == nil then
        -- e.g. code =  "connection refused" or "timeout"
        return true, code
    elseif code ~= 200 and code ~= 201 then
        -- e.g. code = 400, raw_response = "400: Bad Request" or JSON {error message}
        return true, code .. " | Server Response:\n" .. raw_response
    end

    -- Successful Response Handling
    if entity.template then
        return false, raw_response
    end

    if raw_response == "" then
        return false, nil -- Success with no data
    end

    -- Try to decode JSON for actions that return data
    local success, decoded = pcall(rapidjson.decode, raw_response)
    if not success then
        return true, string.format("JSON decode failed:\n%s", decoded)
    end

    -- Successfully decoded JSON.
    return false, decoded
end

--- Build user-facing message based on API response
function HomeAssistant:buildMessage(entity, error, response_data)
    -- on Error:
    if error == true then
        self:buildErrorMessage(entity, response_data)
        -- on Success:
    elseif entity.template then
        self:buildTemplateMessage(entity, response_data)
    elseif entity.action and entity.response_data then
        self:buildResponseDataMessage(entity, response_data)
    elseif entity.action then
        self:buildActionMessage(entity)
    elseif entity.attributes then
        self:buildStateMessage(entity, response_data)
    end
end

--- Helper function to format and display a message
function HomeAssistant:showMessage(title, entity, content, timeout)
    local messageText = string.format(_(
            "%s\n" ..
            "%s\n\n" ..
            "%s"),
        title,
        entity.label,
        content
    )

    UIManager:show(InfoMessage:new {
        text = messageText,
        timeout = timeout,
        icon = icon_value,
    })
end

--- Build error message
function HomeAssistant:buildErrorMessage(entity, response_data)
    local error_content = string.format("⏵ Details:\n%s", response_data)
    self:showMessage("𝙀𝙧𝙧𝙤𝙧", entity, error_content, self.ERROR_MESSAGE_TIMEOUT)
end

--- Build success message for actions / POST requests
function HomeAssistant:buildActionMessage(entity)
    local action_content = string.format("action: %s", entity.action)
    self:showMessage("𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯", entity, action_content, self.SIMPLE_MESSAGE_TIMEOUT)
end

--- Build success message for template evaluation
function HomeAssistant:buildTemplateMessage(entity, response_data)
    self:showMessage("𝘌𝘷𝘢𝘭𝘶𝘢𝘵𝘦 𝘛𝘦𝘮𝘱𝘭𝘢𝘵𝘦", entity, response_data, self.RESPONSE_MESSAGE_TIMEOUT)
end

--- Build success message for state / GET requests
function HomeAssistant:buildStateMessage(entity, response_data)
    -- Named "state", so that later processing matches Home Assistant state object naming
    local state = response_data or {}

    -- Ensure attribute(s) in config.lua are a table (convert single string if needed)
    local attributes = entity.attributes
    if type(attributes) == "string" then
        attributes = { attributes }
        -- as a defensive measure, e.g. user forgets "" around string
    elseif type(attributes) ~= "table" then
        attributes = {}
    end

    local attribute_content

    if #attributes > 0 then
        local attribute_lines = {}

        -- Iterate through user-configured attribute names
        for _, name in ipairs(attributes) do
            -- First check state[attribute_name] (e.g., state.state, state.last_changed)
            -- Then check state.attributes[attribute_name] (e.g., state.attributes.brightness)
            local attribute_value = state[name]
                or (state.attributes and state.attributes[name])

            -- Handle attribute value formatting
            local value = self:formatAttributeValue(attribute_value)
            table.insert(attribute_lines, string.format("%s: %s", name, value))
        end
        attribute_content = table.concat(attribute_lines, "\n")
    else
        attribute_content = "No attributes configured for this entity."
    end

    self:showMessage("𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦", entity, attribute_content, self.RESPONSE_MESSAGE_TIMEOUT)
end

--- Helper function to format any state attribute value into a string
function HomeAssistant:formatAttributeValue(value)
    local value_type = type(value)

    if value == nil or value == rapidjson.null then
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
    local response_content

    -- Handle different kind of actions which use "?return_response"
    if entity.action == "todo.get_items" then
        response_content = self:formatTodoItems(entity, response_data)
    elseif entity.action == "weather.get_forecasts" then
        response_content = self:formatForecasts(entity, response_data)
    else
        -- TODO: Add response data support for other entity types
        -- Fallback message
        response_content = "Configuration error:\nCheck the documentation 'Response Data' section."
    end

    self:showMessage("𝘙𝘦𝘴𝘱𝘰𝘯𝘴𝘦 𝘋𝘢𝘵𝘢", entity, response_content, self.RESPONSE_MESSAGE_TIMEOUT)
end

--- Format todo list items
function HomeAssistant:formatTodoItems(entity, response_data)
    local service_response = response_data.service_response
    local todo_content = ""

    local items = service_response[entity.target].items

    -- Validate that items is a table
    if type(items) == "table" then
        -- Handle empty list
        if #items == 0 then
            return "Your To-do list is empty."
        end

        local todo_parts = {}

        -- PASS 1: Add only the active (non-completed) items first
        for _, item in ipairs(items) do
            if item.status == "needs_action" then
                table.insert(todo_parts, string.format("%s %s", Glyphs.checkbox_blank, tostring(item.summary)))
            end
        end

        -- PASS 2: Add only the completed items at the bottom
        for _, item in ipairs(items) do
            if item.status == "completed" then
                table.insert(todo_parts, string.format("%s %s", Glyphs.checkbox_marked, tostring(item.summary)))
            end
        end

        todo_content = table.concat(todo_parts, "\n")
    end

    return todo_content
end

--- Format forecast list
function HomeAssistant:formatForecasts(entity, response_data)
    local service_response = response_data.service_response

    local display_fields = {
        { key = "condition",     icon = Glyphs.weather,     label = "Cond." },
        { key = "temperature",   icon = Glyphs.thermometer, label = "Temp.",   unit_name = "temperature_unit",   unit_value = "", append_key = "templow" },
        { key = "precipitation", icon = Glyphs.umbrella,    label = "Precip.", unit_name = "precipitation_unit", unit_value = "" },
        { key = "wind_speed",    icon = Glyphs.wind_speed,  label = "Wind.",   unit_name = "wind_speed_unit",    unit_value = "" },
    }

    -- Make a /api/states call to receive the actual value for unit_name = "temperature_unit" etc. and store it in unit_value
    local error, state = self:apiStates(entity)

    if not error and state and state.attributes then
        for _, field in ipairs(display_fields) do
            if field.unit_name then
                -- Overwrite the placeholder with actual value from Home Assistant
                field.unit_value = state.attributes[field.unit_name] or ""
            end
        end
    end

    -- Extract forecast list: [entry1, entry2, entry3, ...] where each entry = one day/hour
    local forecast_list = service_response[entity.target].forecast

    if type(forecast_list) == "table" then
        if #forecast_list == 0 then
            return "Weather forecast is unavailable."
        end

        local output_lines = {}
        local max_entries = 3 -- Configurable limit

        -- OUTER LOOP: Iterate through forecast entries (each entry contains weather data)
        -- for i = start, end, step do
        -- end = math.min(#forecast_list, max_entries); Returns the smaller of the two values
        -- step = 1; increment is implicit
        for entry_index = 1, math.min(#forecast_list, max_entries) do
            -- Extract one forecast entry: { datetime: "...", condition: "sunny", temperature: 22, ... }
            local forecast_entry = forecast_list[entry_index]

            -- Format and display the date/time
            if forecast_entry.datetime then
                local date_line
                local year, month, day, hour, min = forecast_entry.datetime:match(
                    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)%S*")
                local timestamp = os.time({ year = year, month = month, day = day, hour = hour, min = min })

                -- TODO: Decide on how I want to display Dates and Time:
                if entity.data.type == "hourly" then
                    date_line = Glyphs.calendar_clock .. " Time: " .. os.date("%H:%M", timestamp)
                else
                    date_line = os.date("%a %Y-%m-%d", timestamp)
                end
                table.insert(output_lines, date_line)
            end

            -- INNER LOOP: Iterate through display fields (each field = one weather attribute)
            -- For each field.key, extract corresponding data from forecast_entry and format it
            for _, field in ipairs(display_fields) do
                -- Extract the data value using field.key (e.g., forecast_entry["temperature"] = 22)
                -- field.key -> what to extract, field_value -> actual data
                local field_value = forecast_entry[field.key]

                if field_value then
                    local formatted_value = tostring(field_value)
                    -- Text can be appeneded to formatted_value in the following if statements:

                    -- Handle append fields (e.g., temperature & templow: "22 / 15")
                    if field.append_key then
                        local append_value = forecast_entry[field.append_key]
                        if append_value then
                            local formatted_apend_value = tostring(append_value)
                            formatted_value = formatted_value .. " / " .. formatted_apend_value
                        end
                    end

                    -- Append unit if this field has unit support (e.g., "22" becomes "22 °C")
                    if field.unit_value and field.unit_value ~= "" then
                        formatted_value = formatted_value .. " " .. field.unit_value
                    end

                    table.insert(output_lines, string.format("%s %s: %s",
                        field.icon, field.label, formatted_value))
                end
            end

            -- Add separator between forecast entries (but not after the last one)
            if entry_index < max_entries and entry_index < #forecast_list then
                table.insert(output_lines, "────────────────")
            end
        end

        -- Join all formatted lines with newlines and return
        return table.concat(output_lines, "\n")
    end
end

return HomeAssistant
