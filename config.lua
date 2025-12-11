return {
    -- Home Assistant connection settings
    host = "192.168.1.10", -- Change to your Home Assistant IP Address
    port = 8123,           -- Default Home Assistant Port
    token =                -- Change to your own Long-Lived Access Token
    "PasteYourHomeAssistantLong-LivedAccessTokenHere",

    -- Home Assistant Entity configuration
    -- Documentation: https://github.com/moritz-john/homeassistant.koplugin#getting-started
    entities = {
        {
            id = "all",                      -- Entity ID
            domain = "light",                -- Required because Entity ID "all" has no domain
            service = "turn_off",            -- Call HA service (omit to read state instead)
            label = "All Lights → turn_off", -- Display name
        },
        {
            id = "light.reading_lamp",
            service = "toggle",
            label = "Reading Lamp → toggle",
        },
        {
            id = "switch.coffee_machine",
            service = "turn_on",
            label = "♨ Coffee Time",
        },
        {
            id = "sensor.temperature_outside",
            -- NO <service> → read the entity state instead
            label = "Show Temperature Outside",
        },
        {
            id = "light.living_room",
            label = "Light in living room left on?",
        },
        {
            id = "binary_sensor.front_door",
            label = "Is the door closed?",
        },
    },
}
