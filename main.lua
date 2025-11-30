-- homeassistant.koplugin
-- This plugin allows KOReader to control Home Assistant entities through its REST API.

-- Use debug_config.lua if it exists (for development); otherwise config.lua (for end-user)
local ok, ha_config = pcall(require, "debug_config")
if not ok then
    ha_config = require("config")
end

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local HomeAssistant = WidgetContainer:extend {
    name = "homeassistant",
    is_doc_only = false,
}

function HomeAssistant:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- Helper function to get display menu text for an entity
function HomeAssistant:getEntityDisplayText(entity)
    if entity.label ~= nil and entity.label ~= "" then
        return entity.label
    else
        return string.format("%s → (%s)", entity.id, entity.service)
    end
end

-- Register a unique action for each HA entity (e.g. for gestures)
function HomeAssistant:onDispatcherRegisterActions()
    for i, entity in ipairs(ha_config.entities) do
        -- Create a unique action ID for each entity
        local action_id = string.format("ha_entity_%d", i)

        Dispatcher:registerAction(action_id, {
            category = "none",
            event = "ActivateHAEvent",
            arg = entity,
            title = self:getEntityDisplayText(entity),
            general = true,
        })
    end
end

--- Add Tools menu entry with HA entities in submenu
function HomeAssistant:addToMainMenu(menu_items)
    local sub_items = {}

    for _, entity in ipairs(ha_config.entities) do
        table.insert(sub_items, {
            -- Use custom label if provided, otherwise show "entity.id → (service)"
            text = self:getEntityDisplayText(entity),
            callback = function()
                self:onActivateHAEvent(entity)
            end,
        })
    end

    menu_items.homeassistant = {
        text = _("Home Assistant"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

-- Flow: prepareAPICall -> makeAPICall -> display result message to user
function HomeAssistant:onActivateHAEvent(entity)
    local code = self:prepareAPICall(entity)

    -- Display message based on HTTP response code
    if code == 200 or code == 201 then
        -- Success
        UIManager:show(InfoMessage:new {
            text = string.format(_("Success!\n%s\nservice: %s"),
                entity.id, entity.service),
            timeout = 3,
        })
    else
        UIManager:show(InfoMessage:new {
            -- Failure
            text = string.format(_("Failure!\nEntity: %s\nService: %s\nResponse Code: %s"),
                entity.id, entity.service, tostring(code)),
            timeout = 6,
        })
    end
end

function HomeAssistant:prepareAPICall(entity)
    -- Construct Home Assistant API endpoint URL
    local url = string.format("http://%s:%d/api/services/%s",
        ha_config.host, ha_config.port, entity.service)

    -- Prepare JSON request body with entity_id parameter
    local request_body = string.format('{"entity_id": "%s"}', entity.id)

    -- Execute the API call and return the HTTP status code
    local code = self:makeAPICall(url, request_body)

    return code
end

--- Send a POST request to the Home Assistant API
function HomeAssistant:makeAPICall(url, request_body)
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    http.TIMEOUT = 6

    local response_body = {}

    local res, code, headers, status_line = http.request {
        url = url,
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. ha_config.token,
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#request_body)
        },
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body)
    }

    return code
end

return HomeAssistant
