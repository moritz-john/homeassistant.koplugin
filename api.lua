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
        return true, string.format(code)
    elseif code ~= 200 and code ~= 201 then
        -- e.g. code = 400, raw_response = "400: Bad Request" or JSON {error message}
        return true, string.format(code .. " | Server Response:\n" .. raw_response)
    end

    -- Successful Response Handling
    -- /api/template returns plain text, not JSON, so skip the decode path below.
    if entity and (entity.template or entity.attributes) then
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

--- POST /api/services/<domain>/<service> - Call a Home Assistant service
function API:services(entity)
    local domain, action = entity.action:match("^([^.]+)%.(.+)$")
    local url = string.format("%s/api/services/%s/%s",
        self.base_url, domain, action)

    -- Build the JSON body for the service call
    local service_data = {}

    -- Handle 'target' based on type
    -- If it's a Map (Key-Value table, length is 0), merge keys directly into the body
    -- e.g. { entity_id = { "light.foo", "light.bar" } } or { area_id = "flur" }
    if type(entity.target) == "table" and #entity.target == 0 then
        for k, v in pairs(entity.target) do
            service_data[k] = v
        end
    else
        -- If it's a String or an Array (length > 0), assign it to 'entity_id'
        -- e.g. "light.foo" or { "light.a", "light.b" }
        service_data.entity_id = entity.target
    end

    -- Merge additional 'data' attributes if present (e.g. brightness, rgb_color)
    if entity.data then
        for k, v in pairs(entity.data) do
            service_data[k] = v
        end
    end

    return self:performRequest(entity, url, "POST", service_data)
end

--- POST /api/template - Evaluate a Home Assistant template
function API:template(entity)
    local url = string.format("%s/api/template", self.base_url)

    if type(entity.template) ~= "string" or entity.template == "" then
        return true, "No or invalid template configured for this entity."
    end

    -- Strips leading/trailing string whitespace and flattens line indentation
    -- this ensures that indented Lua long-strings ( template = [[ ... ]]) are sent to
    -- to Home Assistant without unintentional formatting or padding.
    local trimmed_template = entity.template:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n%s+", "\n")
    local service_data = { template = trimmed_template }

    return self:performRequest(entity, url, "POST", service_data)
end

-- POST /api/template - Evaluate a custom-made template for entity states & attributes
function API:statesAsTemplate(entity)
    local url = string.format("%s/api/template", self.base_url)

    local attributes = entity.attributes
    -- If it's a string, wrap it in a table. If it's nil or not a table, default to empty table.
    attributes = (type(attributes) == "string") and { attributes } or (type(attributes) == "table" and attributes or {})

    if #attributes == 0 then
        return true, "No attributes configured for this entity."
    end

    local lines = {}

    -- Define target ('t') once so all expressions below can reference it via states[t], state_attr(t, ...) etc.
    table.insert(lines, string.format("{%% set t = '%s' %%}", entity.target))

    for _, attribute in ipairs(attributes) do
        local expression
        if attribute == "state" then
            -- Primary state value (state-level field), formatted with unit_of_measurement if available or a localized display value
            expression =
            "{{ states[t].state_with_unit if state_attr(t, 'unit_of_measurement') else state_translated(t) }}"
        elseif attribute == "last_changed" or attribute == "last_reported" or attribute == "last_updated" then
            -- State-level datetime field, formatted as local time
            expression = string.format("{{ states[t].%s | as_timestamp | timestamp_custom('%%d %%b %%Y, %%H:%%M') }}",
                attribute)
        elseif attribute == "domain" or attribute == "object_id" or attribute == "name" then
            -- Other state-level fields
            expression = string.format("{{ states[t].%s }}", attribute)
        else
            -- Attribute-level field from the entity's attributes dictionary (e.g. brightness, rgb_color)
            expression = string.format("{{ state_attr(t, '%s') }}", attribute)
        end
        table.insert(lines, attribute .. ": " .. expression)
    end

    local service_data = { template = table.concat(lines, "\n") }

    return self:performRequest(entity, url, "POST", service_data)
end

--- Send the current KOReader state to Home Assistant
function API:sendHeartbeat(state, book_title, book_author)
    if not NetworkMgr:isConnected() then
        logger.info("[HomeAssistant]: no network connection, skipping heartbeat")
        return
    end

    local url = string.format("%s/api/states/binary_sensor.%s", self.base_url, self.sensor_name)

    local service_data = {
        state = state,
        attributes = {
            friendly_name = "KOReader Status",
            icon = state == "on" and "mdi:book-variant" or "mdi:book-off",
            device_model = Device.model,
            book_title = book_title or rapidjson.null,
            book_author = book_author or rapidjson.null,
            battery_level = Device:hasBattery() and powerd:getCapacity() or rapidjson.null,
            is_charging = Device:hasBattery() and powerd:isCharging() or false,
            last_seen = os.date("!%Y-%m-%dT%H:%M:%SZ")
        }
    }
    local has_error, response = self:performRequest(nil, url, "POST", service_data)

    if has_error then
        logger.info("[HomeAssistant]: sending heartbeat failed - Error:", response)
    end
end

return API
