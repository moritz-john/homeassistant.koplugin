return {
    -- Home Assistant connection settings
    host = "192.168.1.10", -- Change to your Home Assistant IP Address or Hostname
    port = 8123,           -- Home Assistant Port (usually 443 for HTTPS)
    https = false,         -- Set true only if your Home Assistant is served over HTTPS
    token =                -- Change to your own Long-Lived Access Token
    "PasteYourHomeAssistantLong-LivedAccessTokenHere",

    -- Home Assistant Entity configuration
    -- Documentation: https://github.com/moritz-john/homeassistant.koplugin
    entities = {
        -- Performe Actions:
        {
            label = "All Switches → turn_off",
            action = "switch.turn_off",
            target = "all",
        },
        {
            label = "Reading Lamp → turn_on",
            action = "light.turn_on",
            target = "light.reading_lamp",
        },
        {
            label = "Evening Mood Lights",
            action = "light.turn_on",
            target = { label_id = "evening_mood" },
            data = {
                brightness = 120,
                color_name = "warmwhite",
            },
        },
        {
            label = "Play Jazz",
            action = "media_player.play_media",
            target = "media_player.living_room_sonos",
            data = {
                media_content_type = "music",
                media_content_id = "https://open.spotify.com/playlist/37i9dQZF1DXbITWG1ZJKYt",
            },
        },
        {
            label = "⏯ Play/Pause",
            action = "media_player.media_play_pause",
            target = "media_player.living_room_sonos",
        },
        -- Interactive Actions (with user input):
        {
            label = "Reading Lamp → set brightness",
            action = "light.turn_on",
            target = "light.reading_lamp",
            input = {
                type = "spin",             -- widget type (default: "spin")
                field = "brightness_pct",  -- data key sent to Home Assistant
                title = "Brightness",
                min = 0,
                max = 100,
                step = 5,
                hold_step = 10,
                unit = "%",
                default = 50,
                fetch_current = true,       -- query current value before showing widget
                fetch_attribute = "brightness", -- HA attribute to read (0-255 scale, auto-converted)
            },
        },
        -- Get Entity States:
        {
            label = "Outside Temperature",
            target = "sensor.temperature_outside",
            attributes = { "state", "unit_of_measurement" },
        },
        {
            label = "Is the Front Door Closed?",
            target = "binary_sensor.front_door",
            attributes = { "state", "last_changed" },
        },
        -- Evaluate a Template:
        {
            label = "Inside Temperature",
            template = [[
            {% set my_test_json = {
            "temperature": 25,
            "unit": "°C"
            } %}
            The temperature is {{ my_test_json.temperature }} {{ my_test_json.unit }}.
            ]]
        },
    },
}
