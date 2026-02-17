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
    self:showMessage("𝙀𝙧𝙧𝙤𝙧", entity, error_content, self.TIMEOUTS.ERROR)
end

--- Build success message for actions / POST requests
function Messages:buildActionMessage(entity)
    local action_content = string.format("action: %s", entity.action)
    self:showMessage("𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯", entity, action_content, self.TIMEOUTS.SIMPLE)
end

--- Build success message for template evaluation
function Messages:buildTemplateMessage(entity, response_data)
    self:showMessage("𝘌𝘷𝘢𝘭𝘶𝘢𝘵𝘦 𝘛𝘦𝘮𝘱𝘭𝘢𝘵𝘦", entity, response_data, self.TIMEOUTS.RESPONSE)
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

    self:showMessage("𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦", entity, attribute_content, self.TIMEOUTS.RESPONSE)
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
