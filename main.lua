--- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local InputDialog = require("ui/widget/inputdialog")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
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
-- If the entity has an 'input' field, show an interactive widget first;
-- otherwise execute the action directly.
function HomeAssistant:onActivateHAEvent(entity)
    if entity.input and entity.action then
        self:showInputWidget(entity)
        return
    end
    self:executeAction(entity)
end

--- Execute the actual HA API call
-- Flow: determine endpoint -> call API method -> display result message to user
function HomeAssistant:executeAction(entity)
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

--- Show an interactive input widget before executing an action
-- Routes to the appropriate widget based on input.type.
function HomeAssistant:showInputWidget(entity)
    local input = entity.input
    local input_type = input.type or "spin"

    if input_type == "spin" then
        self:showSpinInput(entity)
    elseif input_type == "choice" then
        self:showChoiceInput(entity)
    elseif input_type == "text" then
        self:showTextInput(entity)
    else
        self:buildMessage(entity, true,
            string.format("Unsupported input type: '%s'", input_type))
    end
end

--- Show a SpinWidget for numeric input, then execute the action with the chosen value
function HomeAssistant:showSpinInput(entity)
    local input = entity.input
    local initial_value = input.default or input.min or 0
    local fetch_info = nil

    -- Optionally fetch the current attribute value from Home Assistant
    if input.fetch_current and entity.target and type(entity.target) == "string" then
        local current, err = self:fetchCurrentAttributeValue(entity, input)
        if current ~= nil then
            initial_value = current
        elseif err then
            fetch_info = "Could not fetch current value: " .. err
        end
    end

    UIManager:show(SpinWidget:new{
        title_text = input.title or entity.label,
        info_text = fetch_info,
        value = initial_value,
        value_min = input.min or 0,
        value_max = input.max or 100,
        value_step = input.step or 1,
        value_hold_step = input.hold_step or 10,
        unit = input.unit or "",
        default_value = input.default,
        ok_always_enabled = true,
        callback = function(spin)
            local modified = self:buildModifiedEntity(entity, spin.value)
            self:executeAction(modified)
        end,
    })
end

--- Show a RadioButtonWidget for selecting from predefined choices
-- Config: input = { type = "choice", field = "color_name", title = "Color",
--                   values = { "red", "blue", "warm_white" }, default = "warm_white" }
function HomeAssistant:showChoiceInput(entity)
    local input = entity.input

    if not input.values or #input.values == 0 then
        self:buildMessage(entity, true, "No 'values' configured for choice input")
        return
    end

    -- Optionally fetch the current value from Home Assistant
    local current_value = input.default
    if input.fetch_current and entity.target and type(entity.target) == "string" then
        local fetched = API:getAttributeValue(entity.target, input.fetch_attribute or input.field)
        if fetched ~= nil then
            current_value = tostring(fetched)
        end
    end

    -- Build radio button rows from the values list
    local radio_buttons = {}
    for _, val in ipairs(input.values) do
        local str_val = tostring(val)
        table.insert(radio_buttons, {
            { text = str_val, provider = val, checked = (str_val == tostring(current_value)) },
        })
    end

    UIManager:show(RadioButtonWidget:new{
        title_text = input.title or entity.label,
        radio_buttons = radio_buttons,
        callback = function(radio)
            local modified = self:buildModifiedEntity(entity, radio.provider)
            self:executeAction(modified)
        end,
    })
end

--- Show an InputDialog for free-form text input
-- Config: input = { type = "text", field = "media_content_id", title = "URL",
--                   default = "", hint = "Enter a URL..." }
function HomeAssistant:showTextInput(entity)
    local input = entity.input

    -- Optionally fetch the current value from Home Assistant
    local current_value = input.default or ""
    if input.fetch_current and entity.target and type(entity.target) == "string" then
        local fetched = API:getAttributeValue(entity.target, input.fetch_attribute or input.field)
        if fetched ~= nil then
            current_value = tostring(fetched)
        end
    end

    local input_dialog
    input_dialog = InputDialog:new{
        title = input.title or entity.label,
        input = current_value,
        input_hint = input.hint or "",
        input_type = input.input_type, -- nil for text, "number" for numeric
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local value = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        local modified = self:buildModifiedEntity(entity, value)
                        self:executeAction(modified)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Create a shallow copy of entity with the user-chosen value merged into data
function HomeAssistant:buildModifiedEntity(entity, value)
    local modified = {}
    for k, v in pairs(entity) do modified[k] = v end
    modified.data = {}
    if entity.data then
        for k, v in pairs(entity.data) do modified.data[k] = v end
    end
    modified.data[entity.input.field] = value
    modified.input = nil -- prevent re-triggering the input widget
    return modified
end

--- Fetch the current value of an entity attribute from Home Assistant
-- Returns (value, nil) on success, or (nil, reason_string) on failure
function HomeAssistant:fetchCurrentAttributeValue(entity, input)
    local attr_name = input.fetch_attribute or input.field
    local value, entity_state = API:getAttributeValue(entity.target, attr_name)
    if type(value) ~= "number" then
        -- If the entity is off, the attribute is likely unavailable;
        -- treat it as "at minimum" (e.g., brightness 0 when light is off)
        if entity_state == "off" then
            return input.min or 0, nil
        end
        return nil, string.format("attribute '%s' is %s (%s)",
            attr_name, tostring(value), type(value))
    end

    -- Handle brightness (0-255) → brightness_pct (0-100) conversion
    if attr_name == "brightness" and input.field == "brightness_pct" then
        value = math.floor(value / 255 * 100 + 0.5)
    end

    return math.max(input.min or 0, math.min(input.max or 100, value)), nil
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
