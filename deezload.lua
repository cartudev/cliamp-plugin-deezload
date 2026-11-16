-- deezload.lua — drive the DeezLoad music bot from the cliamp Telegram pane.
--
-- The core owns the MTProto session. This plugin owns the bot-specific flow:
-- it sends the text, follows the inline results and the callback buttons, and
-- inserts the audio the bot returns. A bot with a different flow needs a
-- different plugin; the core stays generic.
--
-- The action appears under "!" while Telegram is the active provider.
-- Covers are on by default. Turn them off under [plugins.deezload]:
--
--   covers = true                 -- false turns covers off
--   cover_render = "image"        -- "image" (kitty) or "ansi" (half blocks)
--   cover_limit = 3               -- 1..5 covers per search
--   bot_chat = "DeezLoad"        -- the chat where sending is allowed
--   bot_username = "@DeezLoad2bot" -- used to create the chat if missing
--   inline_bot = "@DeezLoadApp"   -- the bot that answers inline queries
--
-- The p:command forms are for scripts and the MCP:
--
--   cliamp plugins call deezload ask <chat-id> /help
--   cliamp plugins call deezload inline <chat-id> "get lucky"
--   cliamp plugins call deezload callback <chat-id> <message-id> <data-b64>

local p = plugin.register({
    name = "deezload",
    type = "hook",
    version = "0.2.0",
    description = "DeezLoad music bot for the cliamp Telegram provider",
    permissions = {"ui", "provider", "provider-send", "control", "image"},
})

-- Covers are optional. Set covers = false under [plugins.deezload] to
-- keep the search text-only. cover_limit caps how many thumbnails load.
local covers = (p:config("covers") or "true"):lower() ~= "false"
local coverLimit = tonumber(p:config("cover_limit") or "3") or 3
coverLimit = math.max(1, math.min(5, coverLimit))
local inlineBot = p:config("inline_bot") or "@DeezLoadApp"
local botChat = p:config("bot_chat") or ""
local botUsername = p:config("bot_username") or "@DeezLoad2bot"
local coverRender = (p:config("cover_render") or "ansi"):lower()

-- The settings action writes here, so a change made in the panel survives a
-- restart without editing config.toml.
local function setting(key, fallback)
    local value = cliamp.store.get(key)
    if value == nil then
        return fallback
    end
    return value
end

covers = setting("covers", covers) == true
coverRender = tostring(setting("cover_render", coverRender)):lower()
coverLimit = math.max(1, math.min(5, tonumber(setting("cover_limit", coverLimit)) or coverLimit))
inlineBot = tostring(setting("inline_bot", inlineBot))
botChat = tostring(setting("bot_chat", botChat))
botUsername = tostring(setting("bot_username", botUsername))

local function render_cover(path)
    if coverRender ~= "ansi" then
        local id = cliamp.image.show("file://" .. path, {cols = 6, rows = 3})
        if id then
            local block = cliamp.image.block(id)
            if block then
                return block, "image"
            end
        end
    end
    local art = cliamp.image.blocks("file://" .. path, {cols = 6, rows = 3})
    return art, "ansi"
end

local function open_bot_chat()
    if botUsername == "" then
        cliamp.message("Set the bot username in Settings first.", 5)
        return
    end
    cliamp.message("Opening " .. botUsername .. "…", 3)
    cliamp.provider.call("telegram.resolve", {username = botUsername}, {
        on_reply = function(chat, err)
            if not chat then
                cliamp.message("Telegram: " .. tostring(err or "bot not found"), 6)
                return
            end
            cliamp.provider.call("telegram.add_chat", {chat = chat.id}, {
                on_reply = function(_, addErr)
                    if addErr then
                        cliamp.message("Add chat: " .. tostring(addErr), 6)
                    end
                    cliamp.provider.call("telegram.send", {chat = chat.id, text = "/start"}, {
                        on_reply = function(sent, sendErr)
                            if not sent then
                                cliamp.message("Telegram: " .. tostring(sendErr), 6)
                                return
                            end
                            local ok, openErr = cliamp.provider.open{
                                provider = "Telegram",
                                playlist_id = chat.id,
                                playlist_name = chat.name,
                                playlist_section = chat.section,
                            }
                            if ok then
                                cliamp.message("Opening " .. chat.name .. "…", 4)
                            else
                                cliamp.message("Open: " .. tostring(openErr), 6)
                            end
                        end,
                    })
                end,
            })
        end,
    })
end

-- Telegram can decorate a dialog title with invisible characters, such as the
-- Hangul filler after "DeezLoad". Strip those and whitespace before comparing,
-- but keep letters from every script so non-Latin names still match.
local function normalize_chat(value)
    value = (value or ""):lower()
    value = value:gsub("%s+", "")
    value = value:gsub("\226\128[\139-\141]", "") -- zero-width space, ZWNJ, ZWJ
    value = value:gsub("\239\187\191", "")         -- byte order mark
    value = value:gsub("\225\133[\160-\168]", "")  -- Hangul fillers
    return value
end

local function is_target_chat(chat, name)
    if botChat == "" then
        return true
    end
    if chat == botChat then
        return true
    end
    local target = normalize_chat((botChat or ""):gsub("^@", ""))
    local got = normalize_chat(name)
    return target ~= "" and got ~= "" and got == target
end

local function current_chat()
    local ctx = cliamp.provider.current()
    if ctx.name ~= "Telegram" then
        return nil, nil
    end
    local chat = ctx.playlist_id
    local name = ctx.playlist_name
    local section = ctx.playlist_section
    if chat == "" then
        chat = ctx.selection_id
        name = ctx.selection_name
        section = ctx.selection_section
    end
    if chat == "" then
        return nil, nil, nil
    end
    return chat, name, section
end

local function insert_track(track)
    if not track or not track.path then
        return
    end
    cliamp.queue.insert(0, track)
    cliamp.message("Added: " .. (track.title or track.path), 5)
end

local function start_payload(links)
    local artist
    for _, link in ipairs(links or {}) do
        local payload = link:match("start=([%w_%-]+)")
        if payload then
            if payload:find("deezertalbum") or payload:find("deezerttrack") then
                return payload
            end
            if not artist then
                artist = payload
            end
        end
    end
    return artist
end

local downloads = {}
local downloadBusy = {}
local lastAudio = {}

local function process_downloads(chat)
    if downloadBusy[chat] then
        return
    end
    local queue = downloads[chat]
    if not queue or #queue == 0 then
        return
    end
    downloadBusy[chat] = true
    local job = table.remove(queue, 1)
    cliamp.message("Downloading " .. job.button.text .. "…", 4)
    cliamp.provider.call("telegram.callback", {
        chat = chat,
        message_id = job.messageID,
        data_b64 = job.button.data_b64,
    }, {
        on_reply = function(_, err)
            if err then
                cliamp.message("Callback: " .. tostring(err), 6)
            end
            local after = (lastAudio[chat] or job.messageID) - 1
            cliamp.provider.call("telegram.reply", {
                chat = chat,
                after = after,
                timeout = 120,
                audio_only = true,
            }, {
                on_reply = function(reply, replyErr)
                    downloadBusy[chat] = false
                    if reply and reply.kind == "audio" and reply.track then
                        insert_track(reply.track)
                        lastAudio[chat] = reply.message_id
                    else
                        cliamp.message("Telegram: " .. tostring(replyErr or (reply and reply.text) or "no audio"), 8)
                    end
                    process_downloads(chat)
                end,
                timeout = 150,
            })
        end,
    })
end

local function enqueue_track(chat, messageID, button)
    downloads[chat] = downloads[chat] or {}
    downloads[chat][#downloads[chat]+1] = {messageID = messageID, button = button}
    cliamp.message("Queued: " .. button.text, 3)
    process_downloads(chat)
end

local ask
local handle_reply

local function album_id(data)
    if not data then
        return nil
    end
    return data:match("album/(%d+)") or data:match("deezer%.com/album/(%d+)")
end

local function button_signature(buttons)
    local parts = {}
    for _, button in ipairs(buttons or {}) do
        parts[#parts+1] = (button.text or "") .. "\0" .. (button.kind or "")
    end
    return table.concat(parts, "\n")
end

local function press_button(chat, messageID, button, previousSignature)
    cliamp.provider.call("telegram.callback", {
        chat = chat,
        message_id = messageID,
        data_b64 = button.data_b64,
    }, {
        on_reply = function(_, err)
            if err then
                cliamp.message("Callback: " .. tostring(err), 8)
            end
        end,
    })

    local function check(attempt)
        cliamp.provider.call("telegram.message", {
            chat = chat,
            message_id = messageID,
        }, {
            on_reply = function(reply, err)
                local signature = button_signature(reply and reply.buttons)
                if reply and signature ~= previousSignature then
                    handle_reply(chat, "", reply, err)
                    return
                end
                if attempt < 5 then
                    cliamp.timer.after(1.5, function()
                        check(attempt + 1)
                    end)
                    return
                end
                -- The callback may have sent a new message instead of editing
                -- the menu in place.
                cliamp.provider.call("telegram.reply", {
                    chat = chat,
                    after = messageID,
                    timeout = 1,
                }, {
                    on_reply = function(newReply, newErr)
                        if newReply and newReply.kind ~= "none" then
                            handle_reply(chat, "", newReply, newErr)
                        else
                            cliamp.message("The bot did not send a new response.", 6)
                        end
                    end,
                })
            end,
        })
    end
    check(1)
end

local function cancel_button(button)
    local text = (button.text or ""):lower()
    return text == "❌" or text == "✖" or text == "✖️" or text == "cancel" or text == "close"
end

local function show_tracks(chat, messageID, buttons)
    local tracks, albums, others = {}, {}, {}
    local trackOptions, albumOptions, otherOptions = {}, {}, {}
    for _, button in ipairs(buttons or {}) do
        local data = button.data_text or ""
        if button.kind == "callback" and button.data_b64 and data:find("deezer.com/track", 1, true) then
            tracks[#tracks+1] = button
            trackOptions[#trackOptions+1] = button.text
        elseif button.kind == "callback" and album_id(data) then
            albums[#albums+1] = button
            albumOptions[#albumOptions+1] = button.text
        elseif button.kind == "callback" and button.data_b64 and not cancel_button(button) then
            others[#others+1] = button
            otherOptions[#otherOptions+1] = button.text
        end
    end
    if #tracks > 0 then
        cliamp.ui.select{
            title = "Tracks",
            options = trackOptions,
            on_select = function(index)
                local button = tracks[index]
                if not button then
                    return
                end
                enqueue_track(chat, messageID, button)
                local remaining = {}
                for _, other in ipairs(tracks) do
                    if other ~= button then
                        remaining[#remaining+1] = other
                    end
                end
                if #remaining > 0 then
                    show_tracks(chat, messageID, remaining)
                else
                    cliamp.message("All tracks queued.", 4)
                end
            end,
        }
        return true
    end
    if #albums > 0 then
        cliamp.ui.select{
            title = "Albums",
            options = albumOptions,
            on_select = function(index)
                local button = albums[index]
                local id = button and album_id(button.data_text)
                if not id then
                    return
                end
                ask(chat, "/start deezertalbum" .. id, function(reply, err)
                    handle_reply(chat, "", reply, err)
                end)
            end,
        }
        return true
    end
    if #others > 0 then
        cliamp.ui.select{
            title = "Buttons",
            options = otherOptions,
            on_select = function(index)
                local button = others[index]
                if button then
                    press_button(chat, messageID, button, button_signature(buttons))
                end
            end,
        }
        return true
    end
    return false
end

ask = function(chat, text, on_reply)
    cliamp.provider.call("telegram.ask", {
        chat = chat,
        text = text,
        timeout = 60,
    }, {
        on_reply = on_reply,
        timeout = 90,
    })
end

local function open_deep_link(chat, reply, query)
    local payload = start_payload(reply.links)
    if not payload then
        cliamp.message(reply.text or "The reply has no link.", 8)
        return
    end
    cliamp.message("Opening " .. payload .. "…", 3)
    ask(chat, "/start " .. payload, function(nextReply, err)
        handle_reply(chat, query, nextReply, err)
    end)
end

local function split_description(description)
    local lines = {}
    for line in (description or ""):gmatch("[^\r\n]+") do
        lines[#lines+1] = line
    end
    return lines[1] or "", lines[2] or ""
end

local function rich_options(results)
    local options = {}
    for _, result in ipairs(results or {}) do
        local subtitle, description = split_description(result.description)
        options[#options+1] = {
            title = (result.title or ""):gsub("[\r\n]+", " "),
            subtitle = subtitle,
            description = description,
        }
    end
    return options
end

local show_inline

local function send_inline_result(chat, query, queryID, result)
    if not result then
        return
    end
    cliamp.provider.call("telegram.send_inline", {
        chat = chat,
        bot = inlineBot,
        query_id = queryID,
        result_id = result.id,
    }, {
        on_reply = function(sent, sendErr)
            if not sent then
                if tostring(sendErr):find("INLINE_RESULT_EXPIRED", 1, true) then
                    cliamp.message("Results expired, refreshing…", 4)
                    show_inline(chat, query)
                    return
                end
                cliamp.message("Inline: " .. tostring(sendErr), 8)
                return
            end
            -- The bot sends the article with the deep link as a separate
            -- message.
            cliamp.provider.call("telegram.reply", {
                chat = chat,
                after = sent.id - 1,
                timeout = 30,
            }, {
                on_reply = function(article, articleErr)
                    handle_reply(chat, query, article, articleErr)
                end,
            })
        end,
    })
end

show_inline = function(chat, query)
    cliamp.provider.call("telegram.inline", {
        chat = chat,
        bot = inlineBot,
        query = query,
    }, {
        on_reply = function(inline, err)
            if not inline or not inline.results or #inline.results == 0 then
                cliamp.message("Telegram: " .. tostring(err or "no inline results"), 8)
                return
            end
            cliamp.ui.select{
                title = "Results",
                options = rich_options(inline.results),
                on_select = function(index)
                    send_inline_result(chat, query, inline.query_id, inline.results[index])
                end,
            }
        end,
    })
end

local open_live_search

local function search_prefix(text)
    local lower = (text or ""):lower()
    if lower:find("track", 1, true) then
        return ".trk "
    end
    if lower:find("artist", 1, true) then
        return ".art "
    end
    return ""
end

local function show_inline_buttons(chat, reply)
    local buttons, options = {}, {}
    for _, button in ipairs(reply.buttons or {}) do
        if button.kind == "switch_inline" and not cancel_button(button) then
            buttons[#buttons+1] = button
            options[#options+1] = button.text
        end
    end
    if #buttons == 0 then
        return false
    end
    cliamp.ui.select{
        title = "Options",
        body = reply.text or "",
        options = options,
        on_select = function(index)
            local button = buttons[index]
            if not button then
                return
            end
            open_live_search(chat, button.text, {}, "search query", search_prefix(button.text))
        end,
    }
    return true
end

local function reply_options(reply)
    local options = {}
    for _, button in ipairs(reply.buttons or {}) do
        if #options >= 50 then
            break
        end
        options[#options+1] = {
            text = button.text,
            kind = button.kind,
            data_b64 = button.data_b64,
            data_text = button.data_text,
            query = button.query,
            send_text = button.send_text,
            url = button.url,
        }
    end
    return options
end

local function remember_reply(chat, reply)
    if not reply or reply.kind == "audio" or reply.message_id == 0 then
        return
    end
    local stored = reply_options(reply)
    local hasButtons = #stored > 0
    if not hasButtons and (not reply.text or reply.text == "") then
        return
    end
    local history = cliamp.store.get("reply_history") or {}
    local out = {
        {
            chat = chat,
            message_id = reply.message_id,
            text = reply.text or "",
            buttons = #stored,
            options = stored,
            at = os.time(),
        },
    }
    for _, old in ipairs(history) do
        if not (old.chat == chat and old.message_id == reply.message_id) and #out < 20 then
            out[#out+1] = old
        end
    end
    cliamp.store.set("reply_history", out)
end

local function forget_reply(chat, messageID)
    local history = cliamp.store.get("reply_history") or {}
    local out = {}
    for _, entry in ipairs(history) do
        if not (entry.chat == chat and entry.message_id == messageID) then
            out[#out+1] = entry
        end
    end
    cliamp.store.set("reply_history", out)
end

local show_history

local function reload_message(chat, messageID)
    cliamp.provider.call("telegram.message", {
        chat = chat,
        message_id = messageID,
    }, {
        on_reply = function(reply, err)
            local empty = not reply or reply.kind == "none" or
                ((not reply.buttons or #reply.buttons == 0) and (not reply.text or reply.text == ""))
            if empty then
                forget_reply(chat, messageID)
                cliamp.ui.text{
                    title = "Previous reply",
                    text = "That saved reply no longer exists in the chat, so it was removed from the history.\n\nNew replies store their options and can be reopened even if the message is gone.",
                    on_close = function()
                        show_history(chat)
                    end,
                }
                return
            end
            handle_reply(chat, "", reply, err)
        end,
    })
end

local function use_stored_option(chat, messageID, button, count)
    if button.kind == "switch_inline" then
        open_live_search(chat, button.text, {}, "search query", search_prefix(button.text))
        return
    end
    if button.send_text then
        ask(chat, button.text, function(reply, err)
            handle_reply(chat, button.text, reply, err)
        end)
        return
    end
    if button.kind == "callback" and button.data_b64 then
        if (button.data_text or ""):find("deezer.com/track", 1, true) then
            enqueue_track(chat, messageID, button)
        else
            press_button(chat, messageID, button, count)
        end
        return
    end
    if button.url and button.url ~= "" then
        cliamp.message(button.url, 8)
    end
end

local function show_history_options(chat, entry, stored)
    local rows = {}
    for _, button in ipairs(stored) do
        rows[#rows+1] = {title = button.text, subtitle = button.kind}
    end
    rows[#rows+1] = {title = "Reload current message", subtitle = "fetch the latest buttons"}
    cliamp.ui.select{
        title = "Previous options",
        options = rows,
        on_cancel = function()
            show_history(chat)
        end,
        on_select = function(choice)
            if choice == #stored + 1 then
                reload_message(chat, entry.message_id)
                return
            end
            local button = stored[choice]
            if not button then
                return
            end
            if button.kind == "callback" and button.data_b64 and
                (button.data_text or ""):find("deezer.com/track", 1, true) then
                enqueue_track(chat, entry.message_id, button)
                local remaining = {}
                for i, other in ipairs(stored) do
                    if i ~= choice then
                        remaining[#remaining+1] = other
                    end
                end
                if #remaining > 0 then
                    show_history_options(chat, entry, remaining)
                else
                    cliamp.message("All tracks queued.", 4)
                end
                return
            end
            use_stored_option(chat, entry.message_id, button, #stored)
        end,
    }
end

show_history = function(chat)
    local history = cliamp.store.get("reply_history") or {}
    local entries = {}
    for _, entry in ipairs(history) do
        if entry.chat == chat then
            entries[#entries+1] = entry
        end
    end
    if #entries == 0 then
        cliamp.message("No previous replies for this chat.", 4)
        return
    end
    local options = {}
    for _, entry in ipairs(entries) do
        local text = (entry.text or ""):gsub("[\r\n]+", " ")
        if text == "" then
            local first = (entry.options or {})[1]
            text = first and first.text or "Bot reply"
        end
        if #text > 64 then
            text = text:sub(1, 61) .. "…"
        end
        local labels = {}
        for _, button in ipairs(entry.options or {}) do
            labels[#labels+1] = button.text
            if #labels >= 5 then
                break
            end
        end
        local summary = table.concat(labels, " · ")
        if summary == "" then
            summary = tostring(entry.buttons or 0) .. " options"
        end
        if #summary > 56 then
            summary = summary:sub(1, 53) .. "…"
        end
        options[#options+1] = {
            title = text,
            subtitle = os.date("%H:%M", entry.at or 0) .. " · " .. summary,
        }
    end
    cliamp.ui.select{
        title = "Previous replies",
        options = options,
        on_select = function(index)
            local entry = entries[index]
            if not entry then
                return
            end
            local stored = entry.options or {}
            if #stored == 0 then
                reload_message(chat, entry.message_id)
                return
            end
            show_history_options(chat, entry, stored)
        end,
    }
end

handle_reply = function(chat, query, reply, err)
    if not reply then
        cliamp.message("Telegram: " .. tostring(err or "no reply"), 8)
        return
    end
    remember_reply(chat, reply)
    if reply.kind == "audio" and reply.track then
        insert_track(reply.track)
        return
    end
    local isCommand = query ~= nil and query:sub(1, 1) == "/"
    local hasButtons = reply.buttons and #reply.buttons > 0
    if hasButtons and reply.text and reply.text ~= "" then
        cliamp.message(reply.text, 8)
    end
    if hasButtons then
        if isCommand then
            if show_inline_buttons(chat, reply) then
                return
            end
        else
            for _, button in ipairs(reply.buttons) do
                if button.kind == "switch_inline" then
                    show_inline(chat, query)
                    return
                end
            end
        end
        if show_tracks(chat, reply.message_id, reply.buttons) then
            return
        end
    end
    if reply.links and start_payload(reply.links) then
        open_deep_link(chat, reply, query)
        return
    end
    if reply.text and reply.text ~= "" then
        cliamp.ui.text{
            title = "Reply",
            text = reply.text,
        }
        return
    end
    cliamp.message("No reply yet. Ctrl+R to reload.", 8)
end

open_live_search = function(chat, title, commands, placeholder, initial)
    local liveResults, liveQueryID, liveQuery = nil, nil, ""
    local liveGen = 0

    local function restore_commands()
        liveResults, liveQueryID = nil, nil
        cliamp.ui.suggestions(commands or {}, {live = false})
    end

    local function fetch_cover(options, results, index, generation, limit)
        if not covers or index > limit or generation ~= liveGen then
            return
        end
        local url = results[index] and results[index].thumb_url
        if url and url ~= "" then
            local body, status = cliamp.http.get(url)
            if body and status == 200 then
                local path = string.format("/tmp/cliamp-tg-cover-%d-%d.img", generation, index)
                if cliamp.fs.write(path, body) then
                    local art = render_cover(path)
                    -- cliamp.image.show reads the source in a goroutine.
                    -- Removing it here races the transmitter: only the first
                    -- image wins, the rest log "no such file".
                    cliamp.timer.after(15, function()
                        cliamp.fs.remove(path)
                    end)
                    if art then
                        options[index].image = art
                        if generation == liveGen then
                            cliamp.ui.suggestions(options, {live = true, query = liveQuery})
                        end
                    end
                end
            end
        end
        cliamp.timer.after(0.05, function()
            fetch_cover(options, results, index + 1, generation, limit)
        end)
    end

    local function search(text)
        liveGen = liveGen + 1
        local generation = liveGen
        cliamp.timer.after(0.35, function()
            if generation ~= liveGen then
                return
            end
            cliamp.provider.call("telegram.inline", {
                chat = chat,
                bot = inlineBot,
                query = text,
            }, {
                on_reply = function(inline, err)
                    if generation ~= liveGen then
                        return
                    end
                    if not inline or not inline.results then
                        cliamp.ui.suggestions({}, {live = true, query = text})
                        return
                    end
                    liveResults = inline.results
                    liveQueryID = inline.query_id
                    liveQuery = text
                    local options = rich_options(inline.results)
                    cliamp.ui.suggestions(options, {live = true, query = text})
                    if covers then
                        cliamp.timer.after(0.05, function()
                            fetch_cover(options, inline.results, 1, generation, math.min(#inline.results, coverLimit))
                        end)
                    end
                end,
            })
        end)
    end

    cliamp.ui.input{
        title = title,
        placeholder = placeholder or "search query",
        value = initial or "",
        suggestions = commands or {},
        on_change = function(text)
            if text == "" or text:sub(1, 1) == "/" or text:match("^https?://") then
                liveGen = liveGen + 1
                restore_commands()
                return
            end
            search(text)
        end,
        on_select = function(index)
            local result = liveResults and liveResults[index]
            if result then
                send_inline_result(chat, liveQuery, liveQueryID, result)
            end
        end,
        on_submit = function(text)
            cliamp.message("Sent. Waiting for the bot…", 3)
            ask(chat, text, function(reply, err)
                handle_reply(chat, text, reply, err)
            end)
        end,
    }
end

local function open_input(chat, name, commands)
    open_live_search(chat, "Message → " .. (name or chat), commands, "song, artist or link")
end

local function save_settings()
    cliamp.store.set("covers", covers)
    cliamp.store.set("cover_render", coverRender)
    cliamp.store.set("cover_limit", coverLimit)
    cliamp.store.set("inline_bot", inlineBot)
    cliamp.store.set("bot_chat", botChat)
    cliamp.store.set("bot_username", botUsername)
end

local function open_settings()
    cliamp.ui.select{
        title = "Telegram bot settings",
        options = {
            {title = "Covers", subtitle = covers and "On" or "Off"},
            {title = "Cover render", subtitle = coverRender},
            {title = "Cover limit", subtitle = tostring(coverLimit)},
            {title = "Inline bot", subtitle = inlineBot},
            {title = "Bot chat", subtitle = botChat ~= "" and botChat or "any bot"},
            {title = "Bot username", subtitle = botUsername},
            {title = "Done"},
        },
        on_select = function(index)
            if index == 1 then
                covers = not covers
                save_settings()
                open_settings()
            elseif index == 2 then
                coverRender = coverRender == "image" and "ansi" or "image"
                save_settings()
                open_settings()
            elseif index == 3 then
                coverLimit = (coverLimit % 5) + 1
                save_settings()
                open_settings()
            elseif index == 4 then
                cliamp.ui.input{
                    title = "Inline bot",
                    placeholder = "@DeezLoadApp",
                    value = inlineBot,
                    on_submit = function(text)
                        if text ~= "" then
                            inlineBot = text
                        end
                        save_settings()
                        open_settings()
                    end,
                    on_cancel = function()
                        open_settings()
                    end,
                }
            elseif index == 5 then
                cliamp.ui.input{
                    title = "Bot chat",
                    placeholder = "DeezLoad or the chat id",
                    value = botChat,
                    on_submit = function(text)
                        botChat = text
                        save_settings()
                        open_settings()
                    end,
                    on_cancel = function()
                        open_settings()
                    end,
                }
            elseif index == 6 then
                cliamp.ui.input{
                    title = "Bot username",
                    placeholder = "@DeezLoad2bot",
                    value = botUsername,
                    on_submit = function(text)
                        botUsername = text
                        save_settings()
                        open_settings()
                    end,
                    on_cancel = function()
                        open_settings()
                    end,
                }
            end
        end,
    }
end

p:action{
    key = "!",
    id = "history",
    label = "Previous replies",
    description = "Reopen a bot response",
    provider = "Telegram",
    context = "chat",
    on_submit = function()
        local chat, name, section = current_chat()
        if not chat then
            cliamp.message("Open a Telegram chat first.", 3)
            return
        end
        if section ~= "Bots" then
            cliamp.message("For now use a private bot chat. Groups and channels are read-only.", 6)
            return
        end
        if not is_target_chat(chat, name) then
            cliamp.message("Open the " .. (botChat ~= "" and botChat or "target bot") .. " chat.", 6)
            return
        end
        show_history(chat)
    end,
}

p:action{
    key = "!",
    id = "settings",
    label = "Settings",
    description = "Covers, render mode and inline bot",
    provider = "Telegram",
    context = "chat",
    on_submit = function()
        open_settings()
    end,
}

p:action{
    key = "!",
    id = "open",
    label = "Open bot chat",
    description = "Start the configured bot chat",
    provider = "Telegram",
    context = "chats",
    on_submit = function()
        open_bot_chat()
    end,
}

p:action{
    key = "!",
    id = "send",
    label = "Send message to this chat",
    description = "Ask the bot for a track",
    provider = "Telegram",
    context = "chat",
    on_submit = function()
        local chat, name, section = current_chat()
        if not chat then
            cliamp.message("Open a Telegram chat first.", 3)
            return
        end
        if section ~= "Bots" then
            cliamp.message("For now use a private bot chat. Groups and channels are read-only.", 6)
            return
        end
        if not is_target_chat(chat, name) then
            cliamp.message("Open the " .. (botChat ~= "" and botChat or "target bot") .. " chat.", 6)
            return
        end
        cliamp.provider.call("telegram.commands", {chat = chat}, {
            on_reply = function(res)
                local suggestions = {}
                for _, command in ipairs(res and res.commands or {}) do
                    suggestions[#suggestions+1] = {
                        title = command.command,
                        description = command.description,
                    }
                end
                open_input(chat, name, suggestions)
            end,
            timeout = 10,
        })
    end,
}

p:command("cover", function(args)
    local url = args[1]
    if not url then
        return "usage: cover <image-url>"
    end
    local body, status = cliamp.http.get(url)
    if not body then
        return "http error: " .. tostring(status)
    end
    local path = "/tmp/cliamp-cover-test.img"
    local ok = cliamp.fs.write(path, body)
    local art, mode = render_cover(path)
    cliamp.timer.after(15, function()
        cliamp.fs.remove(path)
    end)
    return string.format("status=%s bytes=%d write=%s mode=%s art=%s", tostring(status), #body, tostring(ok), tostring(mode), tostring(art and #art))
end)

p:command("ask", function(args)
    local chat = args[1]
    local text = table.concat(args, " ", 2)
    if not chat or chat == "" or text == "" then
        return "usage: ask <chat-id> <message>"
    end
    local reply, err = cliamp.provider.call("telegram.ask", {chat = chat, text = text, timeout = 60})
    if not reply then
        return "error: " .. tostring(err)
    end
    if reply.kind == "audio" and reply.track then
        return "audio: " .. reply.track.title
    end
    return reply.kind .. ": " .. tostring(reply.text)
end)

p:command("inline", function(args)
    local chat = args[1]
    local bot = args[2] or chat
    local query = table.concat(args, " ", 3)
    if not chat or chat == "" or query == "" then
        return "usage: inline <chat-id> [bot] <query>"
    end
    local res, err = cliamp.provider.call("telegram.inline", {chat = chat, bot = bot, query = query})
    if not res then
        return "error: " .. tostring(err)
    end
    local out = {"query_id: " .. tostring(res.query_id)}
    for i, result in ipairs(res.results) do
        out[#out+1] = string.format("%d. %s — %s [%s] id=%s thumb=%s", i, result.title, result.description, result.kind, result.id, tostring(result.thumb_url))
    end
    return table.concat(out, "\n")
end)

p:command("callback", function(args)
    local chat = args[1]
    local messageID = tonumber(args[2] or "0") or 0
    local data = args[3]
    if not chat or messageID == 0 or not data then
        return "usage: callback <chat-id> <message-id> <data-b64>"
    end
    local ok, err = cliamp.provider.call("telegram.callback", {chat = chat, message_id = messageID, data_b64 = data})
    if not ok then
        return "callback error: " .. tostring(err)
    end
    local reply, replyErr = cliamp.provider.call("telegram.reply", {
        chat = chat, after = messageID - 1, timeout = 120, audio_only = true,
    })
    if not reply then
        return "reply error: " .. tostring(replyErr)
    end
    if reply.kind == "audio" and reply.track then
        return "audio: " .. reply.track.title
    end
    return reply.kind .. ": " .. tostring(reply.text)
end)
