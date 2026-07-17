-- CC:Tweaked multi-platform stream chat display
-- Shows Twitch, Kick, and YouTube chat while any enabled platform is live.
-- Shows an offline screen when none of the enabled platforms are live.
--
-- Requirements:
--   1. CC:Tweaked with HTTP and websocket support enabled.
--   2. A monitor is optional. If present, the first attached monitor is used.
--   3. Edit CONFIG below before running.
--
-- Notes:
--   Twitch chat can usually be read anonymously.
--   Kick chat uses the public websocket flow used by the Kick website; it may break if Kick changes it.
--   YouTube chat needs a YouTube Data API key and the live video ID.

local CONFIG = {
    twitch = {
        enabled = true,
        channel = "your_twitch_channel",
    },
    kick = {
        enabled = true,
        channel = "your_kick_channel",
    },
    youtube = {
        enabled = false,
        apiKey = "your_youtube_data_api_key",
        videoId = "your_live_video_id",
    },
}

local CHECK_INTERVAL = 30
local YOUTUBE_POLL_INTERVAL = 6
local MAX_MESSAGES = 80

local TWITCH_UPTIME_URL = "https://decapi.me/twitch/uptime/"
local TWITCH_IRC_WS_URL = "wss://irc-ws.chat.twitch.tv:443"
local KICK_CHANNEL_URL = "https://kick.com/api/v2/channels/"
local KICK_PUSHER_URL = "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=7.4.0&flash=false"
local YOUTUBE_VIDEO_URL = "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=%s&key=%s"
local YOUTUBE_CHAT_URL = "https://www.googleapis.com/youtube/v3/liveChat/messages?liveChatId=%s&part=snippet,authorDetails&key=%s"

local function findDisplay()
    local monitor = peripheral.find("monitor")
    if monitor then
        monitor.setTextScale(0.5)
        return monitor
    end
    return term.current()
end

local display = findDisplay()

local function nowMs()
    return os.epoch("utc")
end

local function clear(bg, fg)
    display.setBackgroundColor(bg or colors.black)
    display.setTextColor(fg or colors.white)
    display.clear()
    display.setCursorPos(1, 1)
end

local function center(y, text, color)
    local w = display.getSize()
    display.setTextColor(color or colors.white)
    display.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
    display.write(text)
end

local function trimToWidth(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return text:sub(1, width)
    end
    return text:sub(1, width - 3) .. "..."
end

local function httpGetBody(url, headers)
    local ok, response = pcall(http.get, url, headers)
    if not ok or not response then
        return nil
    end

    local body = response.readAll()
    response.close()
    return body
end

local function readJson(url, headers)
    local body = httpGetBody(url, headers)
    if not body then
        return nil
    end

    local ok, decoded = pcall(textutils.unserializeJSON, body)
    if ok then
        return decoded
    end
    return nil
end

local function urlEncode(value)
    if textutils.urlEncode then
        return textutils.urlEncode(value)
    end
    return tostring(value):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function addMessage(messages, platform, user, message)
    user = tostring(user or "unknown")
    message = tostring(message or "")
    table.insert(messages, "[" .. platform .. "] " .. user .. ": " .. message)
    while #messages > MAX_MESSAGES do
        table.remove(messages, 1)
    end
end

local function drawOffline(status)
    local _, h = display.getSize()
    clear(colors.black, colors.white)
    center(math.max(1, math.floor(h / 2) - 2), "STREAM CHAT", colors.lightGray)
    center(math.max(1, math.floor(h / 2)), "OFFLINE", colors.red)
    center(math.min(h, math.floor(h / 2) + 2), status or "Checking streams...", colors.gray)
end

local function drawChat(messages, liveNames)
    local w, h = display.getSize()
    clear(colors.black, colors.white)

    display.setCursorPos(1, 1)
    display.setTextColor(colors.lime)
    display.write("LIVE ")
    display.setTextColor(colors.white)
    display.write(trimToWidth(table.concat(liveNames, " + "), math.max(1, w - 5)))

    display.setCursorPos(1, 2)
    display.setTextColor(colors.gray)
    display.write(string.rep("-", w))

    local first = math.max(1, #messages - (h - 3) + 1)
    local row = 3
    for i = first, #messages do
        display.setCursorPos(1, row)
        display.setTextColor(colors.white)
        display.write(trimToWidth(messages[i], w))
        row = row + 1
        if row > h then
            break
        end
    end
end

local function twitchIsLive()
    if not CONFIG.twitch.enabled then
        return false
    end

    local body = httpGetBody(TWITCH_UPTIME_URL .. urlEncode(CONFIG.twitch.channel))
    if not body or body == "" then
        return false
    end

    body = body:lower()
    return not body:find("offline", 1, true) and not body:find("not live", 1, true)
end

local function twitchConnect()
    local ws = http.websocket(TWITCH_IRC_WS_URL)
    ws.send("CAP REQ :twitch.tv/tags")
    ws.send("PASS SCHMOOPIIE")
    ws.send("NICK justinfan" .. tostring(math.random(10000, 99999)))
    ws.send("JOIN #" .. CONFIG.twitch.channel:lower())
    return ws
end

local function twitchRead(ws, messages)
    local raw = ws.receive(0.1)
    if not raw then
        return false
    end

    if raw:sub(1, 4) == "PING" then
        ws.send("PONG :tmi.twitch.tv")
        return false
    end

    local user = raw:match("display%-name=([^;]*)")
    if not user or user == "" then
        user = raw:match(":([^!]+)!")
    end

    local message = raw:match("PRIVMSG #[^ ]+ :(.+)")
    if user and message then
        addMessage(messages, "TW", user, message)
        return true
    end

    return false
end

local function kickGetChannel()
    if not CONFIG.kick.enabled then
        return nil
    end

    return readJson(KICK_CHANNEL_URL .. urlEncode(CONFIG.kick.channel), {
        ["Accept"] = "application/json",
        ["User-Agent"] = "CC-Tweaked",
    })
end

local function kickIsLive()
    local data = kickGetChannel()
    return data and data.livestream ~= nil
end

local function kickChatroomId()
    local data = kickGetChannel()
    if not data then
        return nil
    end
    if data.chatroom and data.chatroom.id then
        return data.chatroom.id
    end
    if data.chatroom_id then
        return data.chatroom_id
    end
    return nil
end

local function kickConnect()
    local chatroomId = kickChatroomId()
    if not chatroomId then
        return nil
    end

    local ws = http.websocket(KICK_PUSHER_URL)
    ws.receive(2)
    ws.send(textutils.serializeJSON({
        event = "pusher:subscribe",
        data = {
            auth = "",
            channel = "chatrooms." .. tostring(chatroomId) .. ".v2",
        },
    }))
    return ws
end

local function kickRead(ws, messages)
    local raw = ws.receive(0.1)
    if not raw then
        return false
    end

    local envelope = textutils.unserializeJSON(raw)
    if not envelope then
        return false
    end

    if envelope.event == "pusher:ping" then
        ws.send(textutils.serializeJSON({ event = "pusher:pong", data = {} }))
        return false
    end

    if envelope.event ~= "App\\Events\\ChatMessageEvent" then
        return false
    end

    local payload = envelope.data
    if type(payload) == "string" then
        payload = textutils.unserializeJSON(payload)
    end
    if not payload then
        return false
    end

    local user = "unknown"
    if payload.sender and payload.sender.username then
        user = payload.sender.username
    elseif payload.user and payload.user.username then
        user = payload.user.username
    elseif payload.username then
        user = payload.username
    end

    local message = payload.content or payload.message
    if message then
        addMessage(messages, "KICK", user, message)
        return true
    end

    return false
end

local youtubeState = {
    liveChatId = nil,
    nextPageToken = nil,
    nextPoll = 0,
}

local function youtubeConfigured()
    return CONFIG.youtube.enabled
        and CONFIG.youtube.apiKey ~= ""
        and CONFIG.youtube.apiKey ~= "your_youtube_data_api_key"
        and CONFIG.youtube.videoId ~= ""
        and CONFIG.youtube.videoId ~= "your_live_video_id"
end

local function youtubeRefreshLiveChatId()
    if not youtubeConfigured() then
        youtubeState.liveChatId = nil
        return false
    end

    local url = string.format(YOUTUBE_VIDEO_URL, urlEncode(CONFIG.youtube.videoId), urlEncode(CONFIG.youtube.apiKey))
    local data = readJson(url)
    local item = data and data.items and data.items[1]
    local details = item and item.liveStreamingDetails
    youtubeState.liveChatId = details and details.activeLiveChatId or nil
    youtubeState.nextPageToken = nil
    return youtubeState.liveChatId ~= nil
end

local function youtubeIsLive()
    if not youtubeConfigured() then
        return false
    end
    if youtubeState.liveChatId then
        return true
    end
    return youtubeRefreshLiveChatId()
end

local function youtubePoll(messages)
    if not youtubeState.liveChatId or nowMs() < youtubeState.nextPoll then
        return false
    end

    local url = string.format(YOUTUBE_CHAT_URL, urlEncode(youtubeState.liveChatId), urlEncode(CONFIG.youtube.apiKey))
    if youtubeState.nextPageToken then
        url = url .. "&pageToken=" .. urlEncode(youtubeState.nextPageToken)
    end

    local data = readJson(url)
    if not data then
        youtubeState.liveChatId = nil
        youtubeState.nextPoll = nowMs() + (CHECK_INTERVAL * 1000)
        return false
    end

    youtubeState.nextPageToken = data.nextPageToken
    youtubeState.nextPoll = nowMs() + ((data.pollingIntervalMillis or (YOUTUBE_POLL_INTERVAL * 1000)))

    local changed = false
    for _, item in ipairs(data.items or {}) do
        local snippet = item.snippet or {}
        local author = item.authorDetails or {}
        local message = snippet.displayMessage
        if message then
            addMessage(messages, "YT", author.displayName or "unknown", message)
            changed = true
        end
    end

    return changed
end

local function closeWs(ws)
    if ws then
        pcall(function()
            ws.close()
        end)
    end
end

local function enabledNames()
    local names = {}
    if CONFIG.twitch.enabled then
        table.insert(names, "Twitch")
    end
    if CONFIG.kick.enabled then
        table.insert(names, "Kick")
    end
    if CONFIG.youtube.enabled then
        table.insert(names, "YouTube")
    end
    return names
end

local function liveNames(live)
    local names = {}
    if live.twitch then
        table.insert(names, "Twitch")
    end
    if live.kick then
        table.insert(names, "Kick")
    end
    if live.youtube then
        table.insert(names, "YouTube")
    end
    return names
end

math.randomseed(nowMs())

local messages = {}
local twitchWs = nil
local kickWs = nil
local live = { twitch = false, kick = false, youtube = false }
local nextLiveCheck = 0

while true do
    if nowMs() >= nextLiveCheck then
        live.twitch = twitchIsLive()
        live.kick = kickIsLive()
        live.youtube = youtubeIsLive()

        if live.twitch and not twitchWs then
            local ok, ws = pcall(twitchConnect)
            twitchWs = ok and ws or nil
        elseif not live.twitch and twitchWs then
            closeWs(twitchWs)
            twitchWs = nil
        end

        if live.kick and not kickWs then
            local ok, ws = pcall(kickConnect)
            kickWs = ok and ws or nil
        elseif not live.kick and kickWs then
            closeWs(kickWs)
            kickWs = nil
        end

        nextLiveCheck = nowMs() + (CHECK_INTERVAL * 1000)
    end

    local names = liveNames(live)
    if #names == 0 then
        closeWs(twitchWs)
        closeWs(kickWs)
        twitchWs = nil
        kickWs = nil
        drawOffline("Watching: " .. table.concat(enabledNames(), ", "))
        sleep(CHECK_INTERVAL)
        nextLiveCheck = 0
    else
        local changed = false

        if twitchWs then
            local ok, didChange = pcall(twitchRead, twitchWs, messages)
            if not ok then
                closeWs(twitchWs)
                twitchWs = nil
                didChange = false
            end
            changed = changed or didChange
        end

        if kickWs then
            local ok, didChange = pcall(kickRead, kickWs, messages)
            if not ok then
                closeWs(kickWs)
                kickWs = nil
                didChange = false
            end
            changed = changed or didChange
        end

        if live.youtube then
            local ok, didChange = pcall(youtubePoll, messages)
            if not ok then
                youtubeState.liveChatId = nil
                didChange = false
            end
            changed = changed or didChange
        end

        if changed or #messages == 0 then
            drawChat(messages, names)
        end

        sleep(0.2)
    end
end
