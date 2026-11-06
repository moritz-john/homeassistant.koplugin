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

-- Fall back to an empty config if homeassistant_config.lua is missing, so the plugin still loads.
local has_config, ha_config = pcall(dofile, config_path)
if not has_config then
    logger.warn("homeassistant: could not load config:", ha_config)
    ha_config = { entities = {} } -- empty entity list: lets all later ha_config.entities loops run without errors
end

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

--- Create the user config on first run
function HomeAssistant:copySampleConfig()
    -- If 'homeassistant_config.lua' already exists, do nothing
    if lfs.attributes(config_path, "mode") == "file" then
        return
    end

    -- Copy the sample config into the settings directory, renaming it to 'homeassistant_config.lua'
    local copy_err = ffiutil.copyFile(self.path .. "/homeassistant_config.sample.lua", config_path)
    if copy_err then
        logger.warn("homeassistant: could not copy sample config:", copy_err)
    end
end

--- Initialize the plugin
function HomeAssistant:init()
    self:copySampleConfig()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    API:init(ha_config)
end

--- Make Home Assistant actions assignable to gestures
function HomeAssistant:onDispatcherRegisterActions()
    -- Combined action: opens a ButtonDialog listing all configured entities
    Dispatcher:registerAction("ha_show_button_dialog", {
        category = "none",
        event = "ShowHAButtonDialog",
        title = "\u{EA5B} Home Assistant: all entities",
        general = true,
        separator = (#ha_config.entities == 0), -- last Home Assistant entry if no entities exist
    })

    -- Individual actions: one gesture action per configured entity
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

    -- First run or unedited sample config: show a "Getting Started" entry that explains the setup steps
    if not has_config or ha_config.show_setup_hint == true then
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

    -- Config is still the shipped example: label the entries below as examples
    if ha_config.show_setup_hint == true then
        table.insert(sub_items, {
            text = "Example entries:",
            enabled = false,
        })
    end

    -- Config loaded but has no entities: show a hint instead of an empty submenu
    if has_config and #ha_config.entities == 0 then
        table.insert(sub_items, {
            text = " \u{ED25} No entities configured",
            callback = function()
                self:buildMessage({ label = "No Entity" }, nil, "No entities configured in 'homeassistant_config.lua'.")
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

--- Handle ShowHAButtonDialog: ButtonDialog listing all entities
function HomeAssistant:onShowHAButtonDialog()
    if #ha_config.entities == 0 then
        self:buildMessage({ label = "No Entity" }, nil, "No entities configured in 'homeassistant_config.lua'.")
        return
    end

    local button_dialog
    local buttons = {} -- list of rows; each row is a list of buttons (here: one button per row)

    for _, entity in ipairs(ha_config.entities) do
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

--- Uninstall hook
function HomeAssistant:deletePluginSettings()
    local ok, err = os.remove(config_path)
    if not ok then
        logger.warn("homeassistant: could not delete", err)
    end
end

return HomeAssistant
