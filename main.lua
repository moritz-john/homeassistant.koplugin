--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local InfoMessage = require("ui/widget/infomessage")
local API = require("homeassistant_api")

-- Fall back to an empty config if homeassistant_config.lua is missing, so the plugin still loads.
local has_config, ha_config = pcall(require, "homeassistant_config")
if not has_config then
    ha_config = { entities = {} }
end

-- Detect an old 'config.lua' that hasn't been renamed yet
local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or "."
local has_legacy_config = package.searchpath("homeassistant_config", plugin_dir .. "/?.lua") == nil
    and package.searchpath("config", plugin_dir .. "/?.lua") ~= nil

-- Entities without a label would crash the menu, so give them a visible placeholder.
for i, entity in ipairs(ha_config.entities) do
    entity.label = entity.label or string.format("Entity %d (missing label in config)", i)
end

local HomeAssistant = WidgetContainer:extend {
    name        = "homeassistant",
    is_doc_only = false,
}

-- Message timeouts in seconds (nil = stays until dismissed)
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

--- Register dispatcher actions for each Home Assistant entity
-- This allows entities to be triggered via gestures.
function HomeAssistant:onDispatcherRegisterActions()
    for i, entity in ipairs(ha_config.entities) do
        -- Internal action id based on the list position, e.g. "ha_entity_1"
        Dispatcher:registerAction(string.format("ha_entity_%d", i), {
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

    -- If homeassistant_config.lua doesn't exist, show "Getting Started" menu entry
    -- (https://yaytext.com/bold-italic/)
    if not has_config and not has_legacy_config then
        table.insert(sub_items, {
            text = _(" \u{EB62} Getting Started (tap for information)"),
            callback = function()
                UIManager:show(InfoMessage:new {
                    text = _(
                        "\n" ..
                        "From your computer:\n" ..
                        "\u{EAA5} Rename '𝘦𝘹𝘢𝘮𝘱𝘭𝘦_𝘤𝘰𝘯𝘧𝘪𝘨.𝘭𝘶𝘢' to '𝗵𝗼𝗺𝗲𝗮𝘀𝘀𝗶𝘀𝘁𝗮𝗻𝘁_𝗰𝗼𝗻𝗳𝗶𝗴.𝗹𝘂𝗮' in the '𝘩𝘰𝘮𝘦𝘢𝘴𝘴𝘪𝘴𝘵𝘢𝘯𝘵.𝘬𝘰𝘱𝘭𝘶𝘨𝘪𝘯' folder.\n\n" ..
                        "\u{EAA8} Edit '𝗵𝗼𝗺𝗲𝗮𝘀𝘀𝗶𝘀𝘁𝗮𝗻𝘁_𝗰𝗼𝗻𝗳𝗶𝗴.𝗹𝘂𝗮' with your Home Assistant URL, token and entities, then restart KOReader.\n\n" ..
                        "\u{E885} Visit https://github.com/moritz-john/homeassistant.koplugin for the full documentation.\n"),
                })
            end,
        })
    end

    if has_legacy_config then
        table.insert(sub_items, {
            text = _(" \u{F071} Rename config.lua (tap for information)"),
            callback = function()
                UIManager:show(InfoMessage:new {
                    text = _(
                        "\n" ..
                        "Rename '𝘤𝘰𝘯𝘧𝘪𝘨.𝘭𝘶𝘢' to '𝗵𝗼𝗺𝗲𝗮𝘀𝘀𝗶𝘀𝘁𝗮𝗻𝘁_𝗰𝗼𝗻𝗳𝗶𝗴.𝗹𝘂𝗮' in the '𝘩𝘰𝘮𝘦𝘢𝘴𝘴𝘪𝘴𝘵𝘢𝘯𝘵.𝘬𝘰𝘱𝘭𝘶𝘨𝘪𝘯' folder, then restart KOReader. The contents stay the same.\n\n" ..
                        "Also make sure that '𝘢𝘱𝘪.𝘭𝘶𝘢' is replaced by the new '𝗵𝗼𝗺𝗲𝗮𝘀𝘀𝗶𝘀𝘁𝗮𝗻𝘁_𝗮𝗽𝗶.𝗹𝘂𝗮'.\n"
                    ),
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

--- Handle ActivateHAEvent (via menu or gesture)
-- Flow: validate entity -> wait for network (re-runs if Wi-Fi was off) -> call matching API method -> show result
function HomeAssistant:onActivateHAEvent(entity)
    if not (entity.action or entity.template or entity.attributes) then
        self:buildMessage(entity, nil, "Invalid config: missing required fields")
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:onActivateHAEvent(entity) end) then
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

--- Build and show a user-facing message based on the API result
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

return HomeAssistant
