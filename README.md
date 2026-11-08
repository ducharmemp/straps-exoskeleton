# straps-exoskeleton

straps-exoskeleton gives straps.nvim users and agents a shared org document for questions, code changes, constraints, and evidence. Both participants can edit the specification and the code; the template imposes no schema.

The project name is straps-exoskeleton. Nix packages and modules use `straps-exoskeleton`; the Lua module remains `straps_collab` and the commands remain `:StrapsCollab` and `:StrapsCollabOpen`.

## Setup

Requires Neovim 0.11 or newer and straps.nvim. Install both plugins on your runtimepath, then register the collaboration entries after straps setup and before creating agent sessions:

```lua
require('straps').setup()
require('straps_collab').setup()
```

`setup(opts)` accepts an optional table, returns the module, and calls the existing `register()` entry. There are no options; unknown keys warn, and non-table arguments raise an error. Registration adds tools and `fn.system_prompt_layer.collab`. Existing transcripts keep their original system prompt. Start a new straps session to receive the prompt fragment. The commands also register entries when invoked, but cannot retrofit a stored system prompt.

orgmode.nvim is optional. Every collaboration buffer receives filetype `org` when loaded. Configure orgmode.nvim yourself for its folding, TODO, agenda, and link features; this plugin does not override its configuration or execute source blocks.

## Start and revisit

From a straps session buffer, run:

```vim
:StrapsCollab my-proposal
```

The command creates a new file and opens it in a split, preserving the transcript window. The command calls the Lua start function with the session context directly, so it does not pass through the tool guard chain. Outside a straps session, it reports an error notification and creates no file. Agents can call `collab_start` with a name or omit the name for a timestamped filename.

Files live in `stdpath('data')/straps/collab`, independent of the current repository. Every start creates a new file: repeated names and timestamp collisions receive numeric suffixes. `collab_open` requires a name, creates or reopens that file, and subscribes the calling session to its saves. A session can subscribe to several notebooks, and several sessions can subscribe to one notebook.

To reopen an existing notebook and subscribe the session you are in, run this from the session buffer:

```vim
:StrapsCollabOpen
:StrapsCollabOpen my-proposal
```

Without a name, the command opens a picker of the notebooks in the collaboration root through straps' `require('straps.ui').pick`, which uses snacks.nvim's picker when installed and `vim.ui.select` otherwise. Each row shows the name, the `#+TITLE` when it is set and differs from the name, the modification time, and the buffer numbers of sessions already subscribed, newest first. Files whose names the command cannot address, such as names with spaces or an uppercase `.ORG`, are left out, so `collab_list` can show files the picker does not. With no notebooks, the command reports the root directory and opens no picker. After a pick, focus returns to the session's window in the current tab before the split opens. With a name, the command opens that notebook directly; `<Tab>` completes names. The command reaches only notebooks directly in the root. It refuses a missing notebook and a loaded notebook buffer whose file is gone from disk. It reuses a window in the current tab that already shows the notebook, otherwise it opens a split. Running it again for a notebook the session already subscribes to keeps that subscription and resets its baseline. Like `:StrapsCollab`, it calls the Lua functions directly and does not pass through the tool guard chain.

Optional `dir` arguments must resolve within the global collaboration directory. File and directory symlinks below that root are refused. These checks prevent accidental escapes; they do not provide a sandbox against another process changing filesystem paths during an operation.

## Save notifications

Subscriptions use buffer-local `BufWritePost` autocmds. They follow buffer renames, deduplicate repeated subscriptions, and coalesce saves queued before the scheduled callback runs. Each subscriber receives one `[straps]` notice through `fn.session_notify`, carrying a unified diff of the saved buffer against what that session last saw: its previous notice, its last `collab_read`, `collab_open`, or `collab_start`, its last `:StrapsCollabOpen`, its own collab write, or the buffer at subscribe time. The notice frames the diff as notebook data, not instructions. A diff over 20000 bytes is replaced by an instruction to call `collab_read`. A save with no changes since the session's last view sends no notice and starts no run. Running agents receive steering. An idle subscriber receives the notice and a new run starts in that session, so the agent reacts to the save; its tool calls still pass through the normal permission gate. When a save starts runs, one `INFO` notification names the session buffers it started.

A subscribed session's own `collab_edit` or `collab_patch` sends it no notice. If that write also saved changes the session had not seen, such as unsaved human edits, the tool result carries their diff, with line numbers of the buffer before the edit. Other subscribers receive a diff that includes the write. Writes made with `noautocmd`, including straps file tools, do not emit `BufWritePost` and therefore do not generate these notices.

Unsubscribing cancels notices still queued in this plugin. Unloading or wiping either the notebook or the session removes that subscription. Notices already delivered to straps cannot be withdrawn. Reopening a notebook after unload requires subscribing again, with `:StrapsCollabOpen`, `collab_open`, or `collab_subscribe`.

Subscriptions last for this Neovim process. Cross-process notifications and notifications for unsaved edits are deferred. Notebook edits neither authorize commands nor change permission grants.

## Tools

- `collab_start {name?, dir?}` creates a unique file, subscribes the calling session, opens the notebook in a split without moving focus, and returns the live buffer content with line numbers.
- `collab_open {name, dir?}` creates or reopens the named file, subscribes the calling session, opens it in a split when no window shows it, and returns the live buffer content. `name` is required.
- `collab_read {bufnr?, name?, dir?}` returns the notebook's live buffer content with line numbers, including unsaved edits. It takes a buffer number or notebook name, never a filesystem path, and declares capability `read` in `fn.capability`. Like the built-in `context` tool, it has no `path` argument for a permission layer to resolve against the project root.
- `collab_edit {bufnr?, name?, dir?, old_string, new_string, replace_all?}` replaces exact text in the notebook buffer as one undo step and saves it.
- `collab_patch {bufnr?, name?, dir?, hunks}` applies 1-based inclusive line hunks (`start_line`, `end_line`, `new_text`, optional `expected_old_text`) to the notebook buffer as one undo step and saves it.
- `collab_subscribe {bufnr?, name?, dir?, path?}` subscribes the calling session to an existing regular file under the collaboration root. `path` remains for compatibility. Later notices diff against the buffer at subscribe time, so call `collab_read` after subscribing.
- `collab_unsubscribe {bufnr?, name?, dir?, path?}` removes that session's subscription without loading a file. When it removes nothing, the result gives the reason.
- `collab_list {}` lists up to 500 regular org files in the root directory, sorted by name, and subscriptions for loaded buffers. It does not create directories or load files; nested directories are not enumerated.

`collab_read`, `collab_edit`, and `collab_patch` each require one of `bufnr` or `name`. Both edit tools declare capability `edit`, take no `path` argument, run the straps disk-change and concurrent-writer checks, stamp the session as the writer, return a diff of unseen changes their write saved when the calling session is subscribed, and notify other subscribers of the save. Agents must not use `read_file`, `edit_file`, `patch_file`, or `write_file` on notebooks. `collab_open` and `collab_start` declare capability `edit`; `collab_subscribe`, `collab_unsubscribe`, `collab_read`, and `collab_list` declare `read`.

`hook.collab_on_write` produces notices under the subscriber's registry scope. It receives `{ buf, file, match, diff }` and returns the notice text; an empty `diff` returns no notice. Hook failures produce an editor error notification, restore the previous scope, and keep the session's baseline, so the next notice includes the missed change.

## Tests

Enter `nix develop` for Neovim, busted, and nlua. Run a focused spec with `busted tests/collab_spec.lua`. Run the full suite with a fresh Neovim per spec:

```sh
fail=0
for spec in tests/*_spec.lua; do
  busted "$spec" || fail=1
done
exit "$fail"
```

`nix flake check path:.` runs the packaged checks against the working directory, including integration against its public Straps input. Unit tests execute the registered Lua source strings with a test registry and real Neovim buffers and autocmds. Run `STRAPS_ROOT=/path/to/straps busted tests/integration_spec.lua` for a local core checkout. The former `STRAPS_TEST_RTP` variable remains a compatibility fallback; without either variable the integration spec reports a pending test. The development shell sets `STRAPS_ROOT` to its Straps input.

## Nix installation

`nix build --no-link path:.` builds the Vim plugin package. The flake exports `packages.<system>.default`, `packages.<system>.straps-exoskeleton`, and `overlays.default` with `vimPlugins.straps-exoskeleton`.

For Nixvim, import both plugins' modules and enable them:

```nix
{
  imports = [
    inputs.straps.nixvimModules.default
    inputs.straps-exoskeleton.nixvimModules.default
  ];
  plugins.straps.enable = true;
  plugins."straps-exoskeleton".enable = true;
}
```

Use your own flake input names in place of `straps` and `straps-exoskeleton`. This flake exports `nixvimModules.default` and `nixvimModules."straps-exoskeleton"` as aliases. The module installs the plugin and appends its registration after straps' normal setup snippet with `lib.mkAfter`. Override `plugins."straps-exoskeleton".package` to use another build. There is no settings option because `register()` takes no configuration.

The module does not enable or configure straps.nvim or orgmode.nvim. Enable straps as shown above; orgmode.nvim remains optional. With this module, omit the manual `require('straps_collab').register()` from the setup instructions.

Without Nixvim, add the package alongside straps.nvim to your Neovim plugin list and use the manual setup above.

The `nixvim-module` flake check evaluates disabled, enabled, custom-package, alias, and setup-order behavior using `lib.evalModules` with a minimal option schema. It is a module contract test, not an evaluation of a complete Nixvim configuration.
