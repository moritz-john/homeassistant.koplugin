--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local Device = require("device")
local powerd = Device:getPowerDevice()
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local Messages = require("messages")

-- Use debug_config.lua if it exists (for development); otherwise config.lua (for end-user)
local ok, ha_config = pcall(require, "debug_config")
if not ok then
    ha_config = require("config")
end

--- Define Home Assisant base_url
local protocol = ha_config.https == true and "https" or "http"
local base_url = string.format("%s://%s:%d", protocol, ha_config.host, ha_config.port)

local HomeAssistant = WidgetContainer:extend {
    name        = "homeassistant",
    is_doc_only = false,
}

HomeAssistant.default_settings = {
    heartbeat_enabled = false
}

--- Initialize the plugin
function HomeAssistant:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self.settings = G_reader_settings:readSetting("homeassistant", self.default_settings)

    -- Guard to ensure sendHeartbeat is only sent once at startup
    if not HomeAssistant._initialized and self.settings.heartbeat_enabled then
        HomeAssistant._initialized = true
        self:sendHeartbeat("on")
    end
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
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

    table.insert(sub_items, {
        text = _("Send KOReader status to HA"),
        separator = true,
        -- checked_func determines if the checkbox is shown as checked
        checked_func = function()
            return self.settings.heartbeat_enabled -- Read from in-memory settings
        end,
        -- callback is executed when the user toggles the checkbox
        callback = function()
            -- Toggle the value in settings
            self.settings.heartbeat_enabled = not self.settings.heartbeat_enabled
            -- Save the settings table to settings.reader.lua under the "homeassistant" key
            G_reader_settings:saveSetting("homeassistant", self.settings)
            -- Force immediate settings write to disk
            G_reader_settings:flush()
            -- Immediate action: update HA status based on the new toggle state
            if self.settings.heartbeat_enabled then
                self:sendHeartbeat("on")
            else
                self:sendHeartbeat("off")
            end
        end,
    })

    -- Add a menu item for each configured Home Assistant entity
    for _, entity in ipairs(ha_config.entities) do
        table.insert(sub_items, {
            text = entity.label,
            callback = function()
                self:onActivateHAEvent(entity)
            end,
        })
    end

    menu_items.homeassistant = {
        text = "\u{EECE} Home Assistant", -- Home Assistant icon font glyph
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

--- Handle ActivateHAEvent
-- Flow: determine endpoint -> call API method -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local error, response_data, extra_data

    if entity.action then
        error, response_data, extra_data = self:apiServices(entity)
    elseif entity.template then
        error, response_data = self:apiTemplate(entity)
    elseif entity.attributes then
        error, response_data = self:apiStates(entity)
    else
        self:buildMessage(entity, true, "Invalid 'config.lua':\nmissing required fields")
        return
    end

    self:buildMessage(entity, error, response_data, extra_data)
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

    -- 1) Fetch Primary Data
    local error, response_data = self:performRequest(entity, url, "POST", service_data)

    -- 2) Fetch state data for weather forecasts to get units
    local extra_data = nil
    if not error and entity.action == "weather.get_forecasts" then
        local state_error, state = self:apiStates(entity)
        if not state_error then
            extra_data = state
        end
    end

    return error, response_data, extra_data
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
    http.TIMEOUT = 6 -- in seconds

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
-- all other messages related code is located in messages.lua
function HomeAssistant:buildMessage(entity, error, response_data, extra_data)
    -- on Error:
    if error == true then
        Messages:buildErrorMessage(entity, response_data)
        -- on Success:
    elseif entity.template then
        Messages:buildTemplateMessage(entity, response_data)
    elseif entity.action and entity.response_data then
        Messages:buildResponseDataMessage(entity, response_data, extra_data)
    elseif entity.action then
        Messages:buildActionMessage(entity)
    elseif entity.attributes then
        Messages:buildStateMessage(entity, response_data)
    end
end

--- Send the current KOReader state to Home Assistant
function HomeAssistant:sendHeartbeat(state)
    local sensor_name = ha_config.koreader_sensor_name or "koreader_status"
    local url = string.format("%s/api/states/binary_sensor.%s", base_url, sensor_name)

    -- Get battery information
    local battery_level = rapidjson.null
    local is_charging = false

    if Device:hasBattery() then
        battery_level = powerd:getCapacity()
        is_charging = powerd:isCharging()
    end

    local service_data = {
        state = state,
        attributes = {
            friendly_name = "KOReader Status",
            icon = state == "on" and "mdi:book-variant" or "mdi:book-off",
            device_model = Device.model,
            battery_level = battery_level,
            is_charging = is_charging,
            last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
    }
    self:performRequest({}, url, "POST", service_data)
end

function HomeAssistant:onSuspend()
    if self.settings.heartbeat_enabled then
        self:sendHeartbeat("off")
    end
end

-- Send "on" state with a delay of 4 seconds (so that the device can reconnect to wifi first)
function HomeAssistant:onResume()
    if self.settings.heartbeat_enabled then
        UIManager:scheduleIn(4, function()
            self:sendHeartbeat("on")
        end)
    end
end

return HomeAssistant
