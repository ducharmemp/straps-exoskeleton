# straps-collab

straps-collab gives straps.nvim users and agents a shared org document for questions, code changes, constraints, and evidence. Both participants can edit the specification and the code; the template imposes no schema.

## Setup

Requires Neovim 0.11 or newer and straps.nvim. Install both plugins on your runtimepath, then register the collaboration entries after straps setup and before creating agent sessions:

```lua
require('straps').setup()
require('straps_collab').register()
```

Registration adds tools and `fn.system_prompt_layer.collab`. Existing transcripts keep their original system prompt. Start a new straps session to receive the prompt fragment. The command also registers entries when invoked, but cannot retrofit a stored system prompt.

orgmode.nvim is optional. Every collaboration buffer receives filetype `org` when loaded. Configure orgmode.nvim yourself for its folding, TODO, agenda, and link features; this plugin does not override its configuration or execute source blocks.

## Start and revisit

From a straps session buffer, run:

```vim
:StrapsCollab my-proposal
```

The command creates a new file and opens it in a split, preserving the transcript window. A replacement `tool.collab_start` must retain a `bufnr: N` response line naming the notebook buffer; the command uses that field to open the split. Outside a straps session, it refuses before creating a file. Agents can call `collab_start` with a name or omit the name for a timestamped filename.

Files live in `stdpath('data')/straps/collab`, independent of the current repository. Every start creates a new file: repeated names and timestamp collisions receive numeric suffixes. `collab_open` reopens an existing named file without subscribing; follow it with `collab_subscribe` to receive save notices. A session can subscribe to several notebooks, and several sessions can subscribe to one notebook.

Optional `dir` arguments must resolve within the global collaboration directory. File and directory symlinks below that root are refused. These checks prevent accidental escapes; they do not provide a sandbox against another process changing filesystem paths during an operation.

## Save notifications

Subscriptions use buffer-local `BufWritePost` autocmds. They follow buffer renames, deduplicate repeated subscriptions, and coalesce saves queued before the scheduled callback runs. Each subscriber receives one short `[straps]` notice through `fn.session_notify`. Running agents receive steering; idle agents are not started.

A current straps writer stamp suppresses a notice to that writer only. Later human edits change the buffer tick and are not suppressed by an older stamp. Writes made with `noautocmd`, including straps file tools, do not emit `BufWritePost` and therefore do not generate these notices.

Unsubscribing cancels notices still queued in this plugin. Unloading or wiping either the notebook or the session removes that subscription. Notices already delivered to straps cannot be withdrawn. Reopening a notebook after unload requires subscribing again.

Subscriptions last for this Neovim process. Cross-process notifications and notifications for unsaved edits are deferred. Notebook edits neither authorize commands nor change permission grants.

## Tools

- `collab_start {name?, dir?}` creates a unique file and subscribes the calling session.
- `collab_open {name?, dir?}` creates or reopens a named file without a subscription.
- `collab_subscribe {path}` subscribes the calling session to an existing regular file under the collaboration root.
- `collab_unsubscribe {path}` removes that session's subscription without loading a file.
- `collab_list {}` lists up to 500 regular org files in the root directory, sorted by name, and subscriptions for loaded buffers. It does not create directories or load files; nested directories are not enumerated.

`hook.collab_on_write` produces notices under the subscriber's registry scope. Hook failures produce an editor error notification and restore the previous scope.

## Tests

Enter `nix develop` for Neovim, busted, and nlua. Run a focused spec with `busted tests/collab_spec.lua`. Run the full suite with a fresh Neovim per spec:

```sh
fail=0
for spec in tests/*_spec.lua; do
  busted "$spec" || fail=1
done
exit "$fail"
```

`nix flake check path:.` runs the packaged checks against the working directory. Unit tests execute the registered Lua source strings with a test registry and real Neovim buffers and autocmds. The integration spec requires a separate straps checkout: run `STRAPS_TEST_RTP=/path/to/straps busted tests/integration_spec.lua`. Without that variable it reports a pending test; the flake check does not fetch straps or run that integration case.

## Nix installation

`nix build --no-link path:.` builds the Vim plugin package. The flake exports `packages.<system>.default`, `packages.<system>.straps-collab`, and `overlays.default` with `vimPlugins.straps-collab`.

Add the package alongside straps.nvim to your Neovim plugin list. The package does not bundle straps.nvim or orgmode.nvim; install and configure those dependencies in your Neovim configuration, using the setup above.
