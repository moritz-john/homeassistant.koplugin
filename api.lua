local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local rapidjson = require("rapidjson")

local API = {
    base_url = nil,
    token = nil,
}

function API:init(ha_config)
    local protocol = ha_config.https == true and "https" or "http"
    self.base_url = string.format("%s://%s:%d", protocol, ha_config.host, ha_config.port)
    self.token = ha_config.token
end

--- Executes a REST request to Home Assistant
-- Only POST requests include service_data / request_body / source
function API:performRequest(entity, url, method, service_data)
    local request_body = service_data and rapidjson.encode(service_data) or nil

    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Content-Type"] = service_data and "application/json" or nil,
        ["Content-Length"] = service_data and tostring(#request_body) or nil
    }

    local response_body = {}

    -- default values from https://github.com/koreader/koreader/blob/22ea2320c56dd5c9b050f2b42423decc0be651e9/frontend/socketutil.lua#L52
    socketutil:set_timeout(5, 15)

    -- Returns: result (1 or nil), code (HTTP status or error text), headers, status line
    -- Only result and code are used here
    local result, code = http.request {
        url = url,
        method = method,
        headers = headers,
        source = service_data and ltn12.source.string(request_body) or nil,
        sink = socketutil.table_sink(response_body)
    }

    socketutil:reset_timeout()

    local raw_response = table.concat(response_body)

    -- Error Handling
    if result == nil then
        -- e.g. code =  "connection refused" or "timeout"
        return nil, tostring(code)
    elseif code ~= 200 and code ~= 201 then
        -- e.g. code = 400, raw_response = "400: Bad Request" or JSON {error message}
        return nil, tostring(code .. " | Server Response:\n" .. raw_response)
    end

    -- Successful Response Handling
    -- /api/template returns plain text, not JSON, so skip the decode path below.
    if entity and (entity.template or entity.attributes) then
        return raw_response
    end

    if raw_response == "" then
        return true -- Success with no data
    end

    -- Try to decode JSON for actions that return data
    local decoded, err = rapidjson.decode(raw_response)
    if decoded == nil then
        return nil, string.format("JSON decode failed:\n%s", tostring(err))
    end

    -- Successfully decoded JSON.
    return decoded
end

--- POST /api/services/<domain>/<service> - Call a Home Assistant service
function API:services(entity)
    local domain, action = tostring(entity.action):match("^([^.]+)%.(.+)$")

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
        return nil, "No or invalid template configured for this entity."
    end

    -- Strips leading/trailing string whitespace and flattens line indentation
    -- this ensures that indented Lua long-strings ( template = [[ ... ]]) are sent to
    -- to Home Assistant without unintentional formatting or padding.
    local trimmed_template = entity.template:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n%s+", "\n")
    local service_data = { template = trimmed_template }

    return self:performRequest(entity, url, "POST", service_data)
end

--- POST /api/template - Evaluate a custom-made template for entity states & attributes
-- Builds a template from the 'attributes' list in the config: one "name: value" line each.
-- Unlike GET /api/states, state and timestamps arrive already formatted (units, translations, local time).
--
-- Example entity:
--   {
--       label = "Temperature Living Room",
--       target = "sensor.living_room_temperature",
--       attributes = { "state", "last_changed", "device_class" },
--   }
--
-- Generated template:
--   {% set t = 'sensor.living_room_temperature' %}
--   state: {{ states[t].state_with_unit if state_attr(t, 'unit_of_measurement') else state_translated(t) }}
--   last_changed: {{ states[t].last_changed | as_timestamp | timestamp_custom('%d %b %Y, %H:%M') }}
--   device_class: {{ state_attr(t, 'device_class') }}
--
-- Rendered response (e.g.):
--   state: 21.5 °C
--   last_changed: 07 Oct 2026, 14:32
--   device_class: temperature
function API:statesAsTemplate(entity)
    local url = string.format("%s/api/template", self.base_url)

    local attributes = entity.attributes
    -- If it's a string, wrap it in a table. If it's nil or not a table, default to empty table.
    attributes = (type(attributes) == "string") and { attributes } or (type(attributes) == "table" and attributes or {})

    if #attributes == 0 then
        return nil, "No attributes configured for this entity."
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

return API
