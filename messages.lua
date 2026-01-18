local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local rapidjson = require("rapidjson")

local Messages = {}

--- Define font glyphs
-- Reference font: koreader/fonts/nerdfonts/symbols.ttf
local Glyphs = {
    checkbox_blank = "\u{E830}",
    checkbox_marked = "\u{E834}",
    calendar_clock = "\u{E7EF}",
    weather = "\u{EC94}",
    thermometer = "\u{EC0E}",
    umbrella = "\u{E220}",
    wind_speed = "\u{EC9C}"
}

--- Helper function to format and display a message
function Messages:showMessage(title, entity, content, timeout)
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
    })
end

--- Build error message
function Messages:buildErrorMessage(entity, response_data)
    local error_content = string.format("⏵ Details:\n%s", response_data)
    self:showMessage("𝙀𝙧𝙧𝙤𝙧", entity, error_content, self.ERROR_MESSAGE_TIMEOUT)
end

--- Build success message for actions / POST requests
function Messages:buildActionMessage(entity)
    local action_content = string.format("action: %s", entity.action)
    self:showMessage("𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯", entity, action_content, self.SIMPLE_MESSAGE_TIMEOUT)
end

--- Build success message for template evaluation
function Messages:buildTemplateMessage(entity, response_data)
    self:showMessage("𝘌𝘷𝘢𝘭𝘶𝘢𝘵𝘦 𝘛𝘦𝘮𝘱𝘭𝘢𝘵𝘦", entity, response_data, self.RESPONSE_MESSAGE_TIMEOUT)
end

--- Build success message for state / GET requests
function Messages:buildStateMessage(entity, response_data)
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
function Messages:formatAttributeValue(value)
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
function Messages:buildResponseDataMessage(entity, response_data, extra_data)
    local response_content

    -- Handle different kind of actions which use "?return_response"
    if entity.action == "todo.get_items" then
        response_content = self:formatTodoItems(entity, response_data)
    elseif entity.action == "weather.get_forecasts" then
        response_content = self:formatForecasts(entity, response_data, extra_data)
    else
        -- Fallback message
        response_content = "Configuration error:\nCheck the documentation 'Response Data' section."
    end

    self:showMessage("𝘙𝘦𝘴𝘱𝘰𝘯𝘴𝘦 𝘋𝘢𝘵𝘢", entity, response_content, self.RESPONSE_MESSAGE_TIMEOUT)
end

--- Format todo list items
function Messages:formatTodoItems(entity, response_data)
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
function Messages:formatForecasts(entity, response_data, extra_data)
    local service_response = response_data.service_response

    local display_fields = {
        { key = "condition",     icon = Glyphs.weather,     label = "Cond." },
        { key = "temperature",   icon = Glyphs.thermometer, label = "Temp.",   unit_name = "temperature_unit",   unit_value = "", append_key = "templow" },
        { key = "precipitation", icon = Glyphs.umbrella,    label = "Precip.", unit_name = "precipitation_unit", unit_value = "" },
        { key = "wind_speed",    icon = Glyphs.wind_speed,  label = "Wind.",   unit_name = "wind_speed_unit",    unit_value = "" },
    }

    -- Process /api/states call to receive the actual value for unit_name = "temperature_unit" etc. and store it in unit_value
    local state = extra_data

    if state and state.attributes then
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

        -- OUTER LOOP: Iterate through forecast_list
        -- for i = start, end, step do
        -- end = math.min(#forecast_list, max_entries); Returns the smaller of the two values
        -- step = 1; increment is implicit
        for entry_index = 1, math.min(#forecast_list, max_entries) do
            -- Get the forecast entry for the current loop iteration.
            -- This data point contains multiple fields (e.g. datetime: "...", condition: "sunny", temperature: 22 )
            local forecast_entry = forecast_list[entry_index]

            -- Format and display the date/time
            if forecast_entry.datetime then
                local date_line
                local year, month, day, hour, min = forecast_entry.datetime:match(
                    "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)%S*")
                local timestamp = os.time({ year = year, month = month, day = day, hour = hour, min = min })

                if entity.data.type == "hourly" then
                    date_line = Glyphs.calendar_clock .. " Time: " .. os.date("%H:%M", timestamp)
                else
                    date_line = Glyphs.calendar_clock .. " Date: " .. os.date("%a %Y-%m-%d", timestamp)
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

return Messages