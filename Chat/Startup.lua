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
--   Twitch EventSub is the current official API path for reading chat.
--   Twitch IRC can still be used as a fallback, but Twitch recommends EventSub.
--   Kick chat uses the public websocket flow used by the Kick website; it may break if Kick changes it.
--   YouTube chat needs a YouTube Data API key and the live video ID.

local CONFIG = {
    twitch = {
        enabled = true,
        channel = "your_twitch_channel",
        mode = "irc", -- "eventsub" for Twitch's current API, or "irc" for simple fallback.
        connectChatEvenIfLiveCheckFails = true,
        eventsub = {
            clientId = "your_twitch_client_id",
            accessToken = "your_twitch_user_access_token",
            broadcasterUserId = "your_twitch_broadcaster_user_id",
            userId = "your_twitch_token_user_id",
        },
    },
    kick = {
        enabled = true,
        channel = "your_kick_channel",
        connectChatEvenIfLiveCheckFails = true,
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
local TWITCH_EVENTSUB_WS_URL = "wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30"
local TWITCH_EVENTSUB_SUBSCRIBE_URL = "https://api.twitch.tv/helix/eventsub/subscriptions"
local KICK_CHANNEL_URL = "https://kick.com/api/v2/channels/"
local KICK_PUSHER_URL = "wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?protocol=7&client=js&version=7.6.0&flash=false"
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

local function decodeJson(value)
    local decoder = textutils.unserializeJSON or textutils.unserialiseJSON
    if not decoder then
        return nil
    end

    local ok, decoded = pcall(decoder, value)
    if ok then
        return decoded
    end
    return nil
end

local function encodeJson(value)
    local encoder = textutils.serializeJSON or textutils.serialiseJSON
    if not encoder then
        return nil
    end

    local ok, encoded = pcall(encoder, value)
    if ok then
        return encoded
    end
    return nil
end

local function readJson(url, headers)
    local body = httpGetBody(url, headers)
    if not body then
        return nil
    end

    return decodeJson(body)
end

local function postJson(url, payload, headers)
    local body = encodeJson(payload)
    if not body then
        return nil
    end

    headers = headers or {}
    headers["Content-Type"] = "application/json"

    local ok, response = pcall(http.post, url, body, headers)
    if not ok or not response then
        return nil
    end

    local responseBody = response.readAll()
    response.close()

    if not responseBody or responseBody == "" then
        return {}
    end
    return decodeJson(responseBody) or {}
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

local function closeWs(ws)
    if ws then
        pcall(function()
            ws.close()
        end)
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

local twitchEventSubConnect
local twitchEventSubRead

local function twitchConnect()
    if CONFIG.twitch.mode == "eventsub" then
        return twitchEventSubConnect()
    end

    local ws = http.websocket(TWITCH_IRC_WS_URL, {
        ["User-Agent"] = "CC-Tweaked Twitch Chat Display",
    })
    ws.send("CAP REQ :twitch.tv/tags")
    ws.send("NICK justinfan" .. tostring(math.random(10000, 99999)))
    ws.send("JOIN #" .. CONFIG.twitch.channel:lower())
    return ws
end

local function twitchEventSubConfigured()
    local eventsub = CONFIG.twitch.eventsub or {}
    return CONFIG.twitch.mode == "eventsub"
        and eventsub.clientId ~= ""
        and eventsub.clientId ~= "your_twitch_client_id"
        and eventsub.accessToken ~= ""
        and eventsub.accessToken ~= "your_twitch_user_access_token"
        and eventsub.broadcasterUserId ~= ""
        and eventsub.broadcasterUserId ~= "your_twitch_broadcaster_user_id"
        and eventsub.userId ~= ""
        and eventsub.userId ~= "your_twitch_token_user_id"
end

local function twitchEventSubSubscribe(sessionId)
    if not twitchEventSubConfigured() then
        return false
    end

    local eventsub = CONFIG.twitch.eventsub
    local response = postJson(TWITCH_EVENTSUB_SUBSCRIBE_URL, {
        type = "channel.chat.message",
        version = "1",
        condition = {
            broadcaster_user_id = eventsub.broadcasterUserId,
            user_id = eventsub.userId,
        },
        transport = {
            method = "websocket",
            session_id = sessionId,
        },
    }, {
        ["Authorization"] = "Bearer " .. eventsub.accessToken,
        ["Client-Id"] = eventsub.clientId,
    })

    return response ~= nil
end

twitchEventSubConnect = function()
    if not twitchEventSubConfigured() then
        return nil
    end

    local ws = http.websocket(TWITCH_EVENTSUB_WS_URL, {
        ["User-Agent"] = "CC-Tweaked Twitch EventSub Display",
    })
    local welcome = ws.receive(8)
    local data = welcome and decodeJson(welcome)
    local session = data and data.payload and data.payload.session
    if not session or not session.id then
        closeWs(ws)
        return nil
    end

    if not twitchEventSubSubscribe(session.id) then
        closeWs(ws)
        return nil
    end

    return ws
end

local function twitchParseLine(line, messages)
    if line:sub(1, 4) == "PING" then
        return "PING"
    end

    local user = line:match("display%-name=([^;]*)")
    if not user or user == "" then
        user = line:match(":([^!]+)!")
    end

    local message = line:match("PRIVMSG #[^ ]+ :(.+)")
    if user and message then
        addMessage(messages, "TW", user, message)
        return true
    end

    return false
end

local function twitchRead(ws, messages)
    if CONFIG.twitch.mode == "eventsub" then
        return twitchEventSubRead(ws, messages)
    end

    local raw = ws.receive(0.1)
    if not raw then
        return false
    end

    local changed = false
    for line in tostring(raw):gmatch("([^\r\n]+)") do
        local result = twitchParseLine(line, messages)
        if result == "PING" then
            ws.send("PONG :tmi.twitch.tv")
        elseif result then
            changed = true
        end
    end

    return changed
end

twitchEventSubRead = function(ws, messages)
    local raw = ws.receive(0.1)
    if not raw then
        return false
    end

    local data = decodeJson(raw)
    if not data or not data.metadata then
        return false
    end

    local messageType = data.metadata.message_type
    if messageType == "session_keepalive" then
        return false
    end

    if messageType == "session_reconnect" then
        local reconnectUrl = data.payload
            and data.payload.session
            and data.payload.session.reconnect_url
        if reconnectUrl then
            error("Twitch EventSub reconnect required")
        end
        return false
    end

    if messageType ~= "notification" then
        return false
    end

    local event = data.payload and data.payload.event
    if not event then
        return false
    end

    local user = event.chatter_user_name or event.chatter_user_login or "unknown"
    local message = event.message and event.message.text
    if message then
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
        ["Referer"] = "https://kick.com/" .. CONFIG.kick.channel,
        ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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

    local ws = http.websocket(KICK_PUSHER_URL, {
        ["Origin"] = "https://kick.com",
        ["Referer"] = "https://kick.com/" .. CONFIG.kick.channel,
        ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    })
    ws.receive(2)
    ws.send(encodeJson({
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

    local envelope = decodeJson(raw)
    if not envelope then
        return false
    end

    if envelope.event == "pusher:ping" then
        ws.send(encodeJson({ event = "pusher:pong", data = {} }))
        return false
    end

    if envelope.event ~= "App\\Events\\ChatMessageEvent" then
        return false
    end

    local payload = envelope.data
    if type(payload) == "string" then
        payload = decodeJson(payload)
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

local twitchWs = nil
local kickWs = nil

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

local function activeChatNames()
    local names = {}
    if twitchWs then
        table.insert(names, "Twitch chat")
    end
    if kickWs then
        table.insert(names, "Kick chat")
    end
    if youtubeState.liveChatId then
        table.insert(names, "YouTube chat")
    end
    return names
end

math.randomseed(nowMs())

local messages = {}
local live = { twitch = false, kick = false, youtube = false }
local nextLiveCheck = 0

while true do
    if nowMs() >= nextLiveCheck then
        live.twitch = twitchIsLive()
        live.kick = kickIsLive()
        live.youtube = youtubeIsLive()

        local wantTwitchChat = CONFIG.twitch.enabled and (live.twitch or CONFIG.twitch.connectChatEvenIfLiveCheckFails)
        local wantKickChat = CONFIG.kick.enabled and (live.kick or CONFIG.kick.connectChatEvenIfLiveCheckFails)

        if wantTwitchChat and not twitchWs then
            local ok, ws = pcall(twitchConnect)
            twitchWs = ok and ws or nil
        elseif not wantTwitchChat and twitchWs then
            closeWs(twitchWs)
            twitchWs = nil
        end

        if wantKickChat and not kickWs then
            local ok, ws = pcall(kickConnect)
            kickWs = ok and ws or nil
        elseif not wantKickChat and kickWs then
            closeWs(kickWs)
            kickWs = nil
        end

        nextLiveCheck = nowMs() + (CHECK_INTERVAL * 1000)
    end

    local names = liveNames(live)
    local chatNames = activeChatNames()
    if #names == 0 and #chatNames == 0 then
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
            if #names == 0 then
                names = chatNames
            end
            drawChat(messages, names)
        end

        sleep(0.2)
    end
end
