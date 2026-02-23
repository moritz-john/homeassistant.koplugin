local _           = require("gettext")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

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
        content = response_data
        timeout = self.TIMEOUTS.RESPONSE
    end

    UIManager:show(InfoMessage:new {
        text    = (
            title .. "\n" ..
            entity.label .. "\n\n" ..
            content),
        timeout = timeout,
    })
end

return Messages
