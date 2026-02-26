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

HomeAssistant.default_settings = {
    heartbeat_enabled = false
}

--- Initialize the plugin
function HomeAssistant:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    API:init(ha_config)

    self.settings = G_reader_settings:readSetting("homeassistant", self.default_settings)

    -- Guard to ensure sendHeartbeat is only sent once at startup
    if not HomeAssistant._initialized and self.settings.heartbeat_enabled then
        HomeAssistant._initialized = true
        API:sendHeartbeat("on", self:getBookInfo())
    end
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
        HomeAssistant:buildMessage(entity, true, "Invalid 'config.lua':\nmissing required fields")
        return
    end

    HomeAssistant:buildMessage(entity, has_error, response_data)
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

    table.insert(sub_items, {
        text = _("Send KOReader status to HA"),
        separator = true,
        -- checked_func determines if the checkbox is shown as checked
        checked_func = function()
            return self.settings.heartbeat_enabled -- Read from in-memory settings
        end,
        -- callback is executed when the user toggles the checkbox
        callback = function()
            -- Toggle the value in settings
            self.settings.heartbeat_enabled = not self.settings.heartbeat_enabled
            -- Save the settings table to settings.reader.lua under the "homeassistant" key
            G_reader_settings:saveSetting("homeassistant", self.settings)
            -- Force immediate settings write to disk
            G_reader_settings:flush()
            -- Immediate action: update HA status based on the new toggle state
            if self.settings.heartbeat_enabled then
                API:sendHeartbeat("on", self:getBookInfo())
            else
                API:sendHeartbeat("off")
            end
        end,
    })

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

function HomeAssistant:getBookInfo()
    if self.ui and self.ui.doc_props then
        local title = self.ui.doc_props.display_title or "Unknown Book"
        local author = (self.ui.doc_props.authors and self.ui.doc_props.authors:gsub("\n", ", ")) or "Unknown Author"
        return title, author
    end
    return nil, nil
end

--- Called when document is fully loaded
function HomeAssistant:onReaderReady()
    if self.settings.heartbeat_enabled then
        API:sendHeartbeat("on", self:getBookInfo())
    end
end

function HomeAssistant:onCloseDocument()
    if self.settings.heartbeat_enabled then
        API:sendHeartbeat("on")
    end
end

function HomeAssistant:onSuspend()
    if self.settings.heartbeat_enabled then
        -- Prevent delayed "on" heartbeat from overriding "off" state
        UIManager:unschedule(API.sendHeartbeat)
        API:sendHeartbeat("off")
    end
end

function HomeAssistant:onResume()
    if self.settings.heartbeat_enabled then
        local delay = ha_config.sensor_resume_delay
        if type(delay) ~= "number" or delay < 0 then delay = 8 end

        local book_title, book_author = self:getBookInfo()
        -- Wait <delay> for WiFi, then send "on"
        -- scheduleIn(delay, function, arg1, arg2...)
        UIManager:scheduleIn(delay, API.sendHeartbeat, API, "on", book_title, book_author)
    end
end

return HomeAssistant
