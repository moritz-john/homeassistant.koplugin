local Device = require("device")
local powerd = Device:getPowerDevice()
local NetworkMgr = require("ui/network/manager")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local logger = require("logger")

local API = {
    base_url = nil,
    token = nil,
    sensor_name = nil,
}

function API:init(ha_config)
    local protocol = ha_config.https == true and "https" or "http"
    self.base_url = string.format("%s://%s:%d", protocol, ha_config.host, ha_config.port)
    self.token = ha_config.token
    self.sensor_name = ha_config.koreader_sensor_name or "koreader_status"
end

--- POST /api/services/<domain>/<service> - Call a Home Assistant service
function API:services(entity)
    local domain, action = entity.action:match("^([^.]+)%.(.+)$")
    local url = string.format("%s/api/services/%s/%s",
        self.base_url, domain, action)

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
function API:template(entity)
    local url = string.format("%s/api/template", self.base_url)

    -- Trim leading and trailing whitespace from each line of a multi-line string
    -- This ensures that indented Lua long-strings ( template = [[ ... ]]) are sent to
    -- Home Assistant without the extra indentation/whitespace from config.lua
    local lines = {}
    for line in entity.template:gmatch("[^\n]+") do
        -- Trim whitespace from each line and store it
        table.insert(lines, line:match("^%s*(.-)%s*$"))
    end

    local trimmed_template = table.concat(lines, "\n")
    local service_data = { template = trimmed_template }

    local error, response_data = self:performRequest(entity, url, "POST", service_data)
    return error, response_data
end

--- GET /api/states/<entity_id> - Fetch entity state from Home Assistant
function API:states(entity)
    local url = string.format("%s/api/states/%s", self.base_url, entity.target)

    local error, response_data = self:performRequest(entity, url, "GET", nil)
    return error, response_data
end

--- Send the current KOReader state to Home Assistant
function API:sendHeartbeat(state, book_title, book_author)
    if not NetworkMgr:isConnected() then
        logger.info("[HomeAssistant]: no network connection, skipping heartbeat")
        return
    end

    local url = string.format("%s/api/states/binary_sensor.%s", self.base_url, self.sensor_name)

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
            book_title = book_title,
            book_author = book_author,
            battery_level = battery_level,
            is_charging = is_charging,
            last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
    }
    local error, response = self:performRequest(nil, url, "POST", service_data)

    if error then
        logger.info("[HomeAssistant]: sending heartbeat failed - Error:", response)
    end
end

--- Executes a REST request to Home Assistant
-- Only POST requests include service_data / request_body / source
function API:performRequest(entity, url, method, service_data)
    http.TIMEOUT = 6 -- in seconds

    local request_body = service_data and rapidjson.encode(service_data) or nil

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
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
    if entity and entity.template then
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

return API
