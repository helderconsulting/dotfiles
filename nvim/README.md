### nvim

new machine:

```bash
git clone <dotfiles> ~/.config
~/.config/nvim/install.sh
```

`install.sh` installs the system tools from `Brewfile`, then runs `bootstrap.lua` headless: plugins at the revisions in `nvim-pack-lock.json`, the blink.cmp prebuilt matcher, treesitter parsers and mason tools. it prints what failed and can be rerun.

`:checkhealth packs` shows what is still missing. the parser and mason lists live in `lua/packs/tools.lua`.

commit `nvim-pack-lock.json` after adding or updating plugins, other machines install from it.
