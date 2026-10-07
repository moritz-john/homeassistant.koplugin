--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local InfoMessage = require("ui/widget/infomessage")
local API = require("api")

-- Check if config.lua exists; if not, fall back to an empty config so the plugin still loads
local has_config, ha_config = pcall(require, "config")
if not has_config then
    ha_config = { entities = {} }
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
-- Flow: validate entity -> wait for network (re-runs if Wi-Fi was off) -> call matching API method -> build/display result message
function HomeAssistant:onActivateHAEvent(entity)
    if not (entity.action or entity.template or entity.attributes) then
        self:buildMessage(entity, nil, "Invalid 'config.lua':\nmissing required fields")
        return
    end

    if NetworkMgr:willRerunWhenOnline(function()
            self:onActivateHAEvent(entity)
        end) then
        return
    end

    local result, err

    if entity.action then
        result, err = API:services(entity)
    elseif entity.template then
        result, err = API:template(entity)
    elseif entity.attributes then
        result, err = API:statesAsTemplate(entity)
    end

    self:buildMessage(entity, result, err)
end

--- Build user-facing message based on API result
function HomeAssistant:buildMessage(entity, result, err)
    local title, content, timeout

    if err then
        title   = "𝙀𝙧𝙧𝙤𝙧"
        content = "⏵ Details:\n" .. err
        timeout = self.TIMEOUTS.ERROR
    elseif entity.action then
        title   = "𝘗𝘦𝘳𝘧𝘰𝘳𝘮 𝘈𝘤𝘵𝘪𝘰𝘯"
        content = "action: " .. entity.action
        timeout = self.TIMEOUTS.SIMPLE
    elseif entity.template then
        title   = "𝘌𝘷𝘢𝘭𝘶𝘢𝘵𝘦 𝘛𝘦𝘮𝘱𝘭𝘢𝘵𝘦"
        content = result
        timeout = self.TIMEOUTS.RESPONSE
    elseif entity.attributes then
        title   = "𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦"
        content = result
        timeout = self.TIMEOUTS.RESPONSE
    end

    UIManager:show(InfoMessage:new {
        text = (
            title .. "\n" ..
            entity.label .. "\n\n" ..
            content),
        timeout = timeout,
    })
end

--- Add Home Assistant submenu to the Tools menu
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

    -- If config.lua doesn't exist, show "Getting Started" menu entry
    if not has_config then
        table.insert(sub_items, {
            text = _(" \u{EB62} Getting Started (tap for information)"),
            callback = function()
                UIManager:show(InfoMessage:new {
                    text = _(
                        "From your computer:\n" ..
                        "\u{EAA5} Rename 'example_config.lua' to 'config.lua' in the 'homeassistant.koplugin' folder.\n" ..
                        "\u{EAA8} Edit 'config.lua' with your Home Assistant URL, token and entities, then restart KOReader.\n\n" ..
                        "\u{E885} Visit https://github.com/moritz-john/homeassistant.koplugin for the full documentation."),
                })
            end,
        })
    end

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
