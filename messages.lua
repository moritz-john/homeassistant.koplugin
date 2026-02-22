local _           = require("gettext")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local rapidjson   = require("rapidjson")

local Messages    = {}

-- Define message timeouts (in seconds)
Messages.TIMEOUTS = {
    SIMPLE   = 5,
    RESPONSE = nil,
    ERROR    = nil
}

--- Build user-facing message based on API response
function Messages:build(entity, has_error, response_data)
    local title, content, timeout
    if has_error then
        title   = "𝙀𝙧𝙧𝙤𝙧"
        content = "⏵ Details:\n" .. tostring(response_data)
        timeout = self.TIMEOUTS.ERROR
    elseif entity.action then
        title   = "𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯"
        content = "action: " .. entity.action
        timeout = self.TIMEOUTS.SIMPLE
    elseif entity.template then
        title   = "𝘌𝘷𝘢𝘭𝘶𝘢𝘵𝘦 𝘛𝘦𝘮𝘱𝘭𝘢𝘵𝘦"
        content = response_data
        timeout = self.TIMEOUTS.RESPONSE
    elseif entity.attributes then
        title   = "𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦"
        content = self:buildStateContent(entity, response_data) -- unchanged
        timeout = self.TIMEOUTS.RESPONSE
    end

    self:show(entity, title, content, timeout)
end

--- Helper function to format and display a message
function Messages:show(entity, title, content, timeout)
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

--- Build success message for state / GET requests
function Messages:buildStateContent(entity, response_data)
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

    if #attributes == 0 then
        return "No attributes configured for this entity."
    end

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

    return table.concat(attribute_lines, "\n")
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

return Messages
