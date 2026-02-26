return {
    -- Home Assistant connection settings
    host = "192.168.1.10", -- Change to your Home Assistant IP Address or Hostname
    port = 8123,           -- Home Assistant Port (usually 443 for HTTPS)
    https = false,         -- Set true only if your Home Assistant is served over HTTPS
    token =                -- Change to your own Long-Lived Access Token
    "PasteYourHomeAssistantLong-LivedAccessTokenHere",

    -- KOplugin settings
    koreader_sensor_name = "koreader_status", -- Name of the binary_sensor in Home Assistant (e.g., binary_sensor.koreader_status)
    sensor_resume_delay = 8,                  -- Delay (in seconds) until a status update is send to Home Assistant after waking up the ebook reader

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
