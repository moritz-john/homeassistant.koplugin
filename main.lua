--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local API = require("api")

-- Use debug_config.lua if it exists (for development); otherwise config.lua (for end-user)
local ok, ha_config = pcall(require, "debug_config")
if not ok then
    ha_config = require("config")
end

local HomeAssistant = WidgetContainer:extend {
    name        = "homeassistant",
    is_doc_only = false,
}

-- Define message timeouts (in seconds)
HomeAssistant.TIMEOUTS = {
    SIMPLE   = 5,
    RESPONSE = nil,
    ERROR    = nil
}

--- Initialize the plugin
function HomeAssistant:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    API:init(ha_config)
end

--- Handle ActivateHAEvent (via menu or gesture)
-- Flow: determine endpoint -> call API method -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local has_error, response_data

    if entity.action then
        has_error, response_data = API:services(entity)
    elseif entity.template then
        has_error, response_data = API:template(entity)
    elseif entity.attributes then
        has_error, response_data = API:statesAsTemplate(entity)
    else
        self:buildMessage(entity, true, "Invalid 'config.lua':\nmissing required fields")
        return
    end

    self:buildMessage(entity, has_error, response_data)
end

--- Build user-facing message based on API response
function HomeAssistant:buildMessage(entity, has_error, response_data)
    local title, content, timeout
    if has_error then
        title   = "𝙀𝙧𝙧𝙤𝙧"
        content = "⏵ Details:\n" .. response_data
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

--- Add Home Assistant submenu to the Tools menu
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

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

return HomeAssistant
