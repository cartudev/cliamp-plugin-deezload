[![lua](https://github.com/cartudev/cliamp-plugin-deezload/actions/workflows/lua.yml/badge.svg)](https://github.com/cartudev/cliamp-plugin-deezload/actions/workflows/lua.yml)

# cliamp-plugin-deezload

A [cliamp](https://github.com/bjarneo/cliamp) plugin for the
[DeezLoad](https://t.me/DeezLoad2bot) music bot, driven from the Telegram
provider pane.

The core owns the MTProto session and the generic write actions. This plugin
owns the DeezLoad flow: the command palette, the live inline search with the
`@DeezLoadApp` bot, covers, the option buttons, the reply history and the
settings panel. The core stays free of DeezLoad-specific code.

## Features

- `!` action pane with **Send message to this chat**, **Previous replies**,
  **Settings** and **Open bot chat**.
- Bot command menu from `bots.getBotCommands`; type a song, artist or link
  directly, with live inline results from `@DeezLoadApp`.
- Covers next to inline results, as terminal images or ANSI half blocks.
- Audio replies and callback buttons go to the queue; `.trk` and `.art`
  shortcuts, deep links, TOP 30 and `/start` payloads are handled.
- Reply history keeps the options even after the Telegram message is gone.
- Settings live in `[plugins.deezload]` and in the panel; no config edit
  required.

## Install

```sh
mkdir -p ~/.config/cliamp/plugins
curl -fsSL https://raw.githubusercontent.com/cartudev/cliamp-plugin-deezload/main/deezload.lua \
  -o ~/.config/cliamp/plugins/deezload.lua
cliamp plugins trust deezload
```

The plugin declares `ui`, `provider`, `provider-send`, `control` and `image`
permissions. It needs a cliamp build with the plugin provider API (`p:action`,
`cliamp.provider.*`, `cliamp.ui.input`, `cliamp.ui.text`, `ui.suggestions` and
`cliamp.provider.open`), currently proposed in the stacked PRs
[bjarneo/cliamp#726](https://github.com/bjarneo/cliamp/pull/726),
[#727](https://github.com/bjarneo/cliamp/pull/727),
[#728](https://github.com/bjarneo/cliamp/pull/728) and
[#729](https://github.com/bjarneo/cliamp/pull/729).

## Configure

```toml
[plugins.deezload]
covers = true
cover_render = "ansi"          # "image" uses the terminal image protocol
cover_limit = 3                # 1..5 covers per search
bot_chat = "DeezLoad"          # the chat where sending is allowed
bot_username = "@DeezLoad2bot" # used to create the chat if it is missing
inline_bot = "@DeezLoadApp"    # the bot that answers inline queries
```

The same values are in **Settings** in the `!` pane. The settings panel writes
to cliamp's plugin store, so a change made there survives a restart without
editing `config.toml`.

## Usage

Open the Telegram provider, open the DeezLoad chat (or use **Open bot chat**
from the chat list), then press `!`:

- **Send message to this chat** asks for a song, artist or link. Typing also
  searches `@DeezLoadApp` inline; `Enter` sends the selected result.
- **Previous replies** reopens a saved reply with its original buttons.
- **Settings** edits covers, render mode, cover limit and the bot fields.
- **Open bot chat** resolves `bot_username`, adds it to the `chats` filter when
  one is set, sends `/start`, and opens the chat.

## Scope and caveats

- For now writes are limited to the private chat in `bot_chat`. Groups and
  channels stay read-only until the invite and permission flow exists.
- `cover_render = "image"` depends on the terminal. Use `"ansi"` when the
  terminal does not support the image protocol.
- `.trk` and `.art` are the confirmed DeezLoad prefixes. Other `/start` buttons
  can return mixed results.
- The plugin sends as your account through cliamp's MTProto session. Keep the
  session file private; it can send messages and press buttons for you.

## Commands

The `p:command` forms are for scripts and the MCP:

```sh
cliamp plugins call deezload ask <chat-id> /help
cliamp plugins call deezload inline <chat-id> "get lucky"
cliamp plugins call deezload callback <chat-id> <message-id> <data-b64>
```

## License

MIT
