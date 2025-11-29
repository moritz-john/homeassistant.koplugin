return {
    -- Home Assistant connection settings
    host = "192.168.1.10", -- Change to your Home Assistant IP Address
    port = 8123,           -- Default Home Assistant Port
    token =                -- Change to your own Long-Lived Access Token
    "PasteYourHomeAssistantLong-LivedAccessTokenHere",

    -- Home Assistant Entity configuration
    -- Documentation: https://sputge.com/docs/homeassistant_koplugin/#installation--configuration
    entities = {
        {
            id = "light.reading_lamp",      -- Home Assistant Entity ID
            service = "light/toggle",       -- <domain>/<service>
            label = "Toggle: Reading Lamp", -- Optional: custom menu label
        },
        {
            id = "light.all_lights",
            service = "light/turn_on",
            label = "Turn on ALL lights",
        },
        {
            id = "switch.coffee_machine",
            service = "switch/turn_on",
            label = "Coffee Time",
        },
        {
            id = "fan.ceiling_fan",
            service = "fan/turn_on",
            label = "",
        },
    },
}
