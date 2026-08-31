# Neovim IDE with Pi Agent

A Neovim configuration based on [kickstart.nvim](https://github.com/nvim-lua/kickstart.nvim) that integrates the Pi AI coding assistant as a side window, provides a first-run setup for API keys, and highlights LLM-suggested changes until accepted.

## Features

- Language Server Protocol support for:
  - Rust (`rust_analyzer`)
  - Go (`gopls`)
  - Python (`pyright`)
  - C/C++ (`clangd`)
  - Lua (`lua_ls`)
  - YAML (`yamlls`)
  - JSON (`jsonls`)
  - TOML (`taplo`)
  - Groovy (`groovyls`)
- Side terminal window running Pi agent (`<leader>tp`)
- First-start interface to reuse an existing Pi login or configure an API-key/provider override
- Commands to request code suggestions from Pi and highlight them:
  - `:PiSuggest` – get suggestions for current buffer (or visual selection)
  - `:PiAccept` – apply all pending suggestions
  - `:PiDiscard` – discard pending suggestions
- Highlighted suggestions appear with a background color until accepted or discarded.
- Standard kickstart.nvim features (telescope, lsp, autocomplete, treesitter, etc.)

## Installation

Clone this repository to `~/.config/nvim` (or `~/nvim-pi-ide` and set `$MYVIMRC` accordingly):

```bash
git clone https://github.com/yourusername/nvim-pi-ide.git ~/.config/nvim
```

Start Neovim. On first run, choose whether to reuse the existing Pi login from `~/.pi/agent/auth.json` (recommended) or configure a separate provider/API-key override.

## Usage

- Open Pi side terminal: `<leader>tp`
- In the terminal, you can interact with Pi directly.
- To get code suggestions from the current buffer:
  - Enter visual mode and select a range, or just place the cursor anywhere.
  - Run `:PiSuggest` (range-aware) to ask Pi to suggest edits.
  - Pi's suggested changes will be applied and highlighted.
  - Review the changes.
  - Run `:PiAccept` to keep the changes permanently.
  - Run `:PiDiscard` to revert the suggestions and restore original code.

## Configuration

The integration profile is stored in `~/.local/share/nvim/pi_config.json` (or `$XDG_DATA_HOME/nvim/pi_config.json`) with user-only permissions. Run `:PiSetup` to change it.

When **Use existing Pi login** is selected, credentials and the default model remain managed by Pi in `~/.pi/agent/auth.json` and `~/.pi/agent/settings.json`; the Neovim profile does not copy them. Use `/login` and `/model` inside Pi to change that base configuration.

## Extending

Add custom plugins in `lua/custom/plugins/`; any `.lua` file there will be automatically loaded.

## License

MIT