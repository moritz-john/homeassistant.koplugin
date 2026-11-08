--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local logger = require("logger")
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")
local API = require("homeassistant_api")

local config_path = DataStorage:getSettingsDir() .. "/homeassistant_config.lua"

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

--- Load the user config into self.config.
-- self.config always has an `entities` list; self.has_config is false if the config is broken or invalid.
function HomeAssistant:loadConfig()
    -- No user config yet: copy the sample into the settings directory
    if lfs.attributes(config_path, "mode") ~= "file" then
        local copy_err = ffiutil.copyFile(self.path .. "/homeassistant_config.sample.lua", config_path)
        if copy_err then
            logger.warn("homeassistant: could not copy sample config:", copy_err)
        end
    end

    local ok, result = pcall(dofile, config_path) -- execute config file, catch errors

    -- Valid = ran without errors, returned a table (i.e. has 'return { ... }') containing an 'entities' table
    local has_config = ok and type(result) == "table" and type(result.entities) == "table"
    -- Use the config if valid, otherwise an empty entity list so later entity loops don't fail
    local ha_config = has_config and result or { entities = {} }

    if not has_config then
        logger.warn("homeassistant: could not load config:", result)
    end

    -- Entities without a label would crash the menu, so give them a visible placeholder.
    for i, entity in ipairs(ha_config.entities) do
        entity.label = entity.label or string.format("Entity %d (missing label in config)", i)
    end

    self.has_config, self.config = has_config, ha_config
end

--- Initialize the plugin
function HomeAssistant:init()
    self:loadConfig()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    API:init(self.config)
end

--- Make Home Assistant actions assignable to gestures
function HomeAssistant:onDispatcherRegisterActions()
    local entities = self.config.entities

    -- Combined action: opens a ButtonDialog listing all configured entities
    Dispatcher:registerAction("ha_show_button_dialog", {
        category = "none",
        event = "ShowHAButtonDialog",
        title = "\u{EA5B} Home Assistant: all entities",
        general = true,
        separator = (#entities == 0), -- last Home Assistant entry if no entities exist
    })

    -- Individual actions: one gesture action per configured entity
    -- Ids are position-based, so reordering or deleting entities remaps existing gestures.
    for i, entity in ipairs(entities) do
        Dispatcher:registerAction(string.format("ha_entity_%d", i), {
            category = "none",
            event = "ActivateHAEvent",
            arg = entity,
            title = entity.label,
            general = true,
            separator = (i == #entities), -- add separator after last entity
        })
    end
end

--- Add Home Assistant submenu to the Tools menu
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

    -- Config missing/broken or still the shipped example: show a "Getting Started" entry that explains the setup steps
    if not self.has_config or self.config.show_setup_hint == true then
        table.insert(sub_items, {
            text = "\u{EB62} Getting Started (tap for information)",
            callback = function()
                UIManager:show(InfoMessage:new {
                    text =
                        "From your computer:\n\n" ..
                        "\u{EAA5} Go to 'koreader/settings/' and edit 'homeassistant_config.lua'\n\n" ..
                        "\u{EAA8} Configure your host, token and entities, then restart KOReader.\n\n" ..
                        "\u{E885} Full documentation: https://github.com/moritz-john/homeassistant.koplugin\n",
                })
            end,
        })
    end

    -- Config could not be loaded or is invalid: point the user to the log
    if not self.has_config then
        table.insert(sub_items, {
            text = "Config could not be loaded (see crash.log)",
            enabled = false,
        })
    end

    -- Config is still the shipped example: label the entries below as examples
    if self.config.show_setup_hint == true then
        table.insert(sub_items, {
            text = "Example entries:",
            enabled = false,
        })
    end

    -- Config loaded but has no entities: show a hint instead of an empty submenu
    if self.has_config and #self.config.entities == 0 then
        table.insert(sub_items, {
            text = " \u{ED25} No entities configured",
            callback = function()
                self:buildMessage({ label = "No Entity" }, nil, "No entities configured in 'homeassistant_config.lua'.")
            end,
        })
    end

    -- Add a menu item for each configured Home Assistant entity
    for _, entity in ipairs(self.config.entities) do
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

--- Handle ShowHAButtonDialog: ButtonDialog listing all entities
function HomeAssistant:onShowHAButtonDialog()
    if #self.config.entities == 0 then
        self:buildMessage({ label = "No Entity" }, nil, "No entities configured in 'homeassistant_config.lua'.")
        return
    end

    local button_dialog
    local buttons = {} -- list of rows; each row is a list of buttons (here: one button per row)

    for _, entity in ipairs(self.config.entities) do
        table.insert(buttons, {
            {
                text = entity.label,
                align = "left",
                callback = function()
                    UIManager:close(button_dialog) -- close the dialog first
                    self:onActivateHAEvent(entity)
                end,
            },
        })
    end

    button_dialog = ButtonDialog:new {
        title = "\u{EECE} Home Assistant",
        title_align = "center",
        width_factor = 0.6,
        buttons = buttons,
    }
    UIManager:show(button_dialog)
end

--- Handle ActivateHAEvent (via menu or gesture)
-- Flow: validate entity -> wait for network (re-runs if Wi-Fi was off) -> call matching API method -> show result
function HomeAssistant:onActivateHAEvent(entity)
    if not (entity.action or entity.template or entity.attributes) then
        self:buildMessage(entity, nil, "Invalid config: missing required fields")
        return
    end

    -- Offline: queues a re-run once Wi-Fi is up, so stop here.
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
        content = result or ""
        timeout = self.TIMEOUTS.RESPONSE
    elseif entity.attributes then
        title   = "𝘙𝘦𝘤𝘦𝘪𝘷𝘦 𝘚𝘵𝘢𝘵𝘦"
        content = result or ""
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

--- Uninstall hook
function HomeAssistant:deletePluginSettings()
    local ok, err = os.remove(config_path)
    if not ok then
        logger.warn("homeassistant: could not delete", err)
    end
end

return HomeAssistant
