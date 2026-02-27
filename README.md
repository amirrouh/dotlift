# dotlift

Migrate from bash to a fully configured zsh in one command.

dotlift reads a single `config.yaml` and handles everything: installs zsh, Oh My Zsh, your chosen theme and plugins, a curated set of modern CLI tools, migrates your bash aliases and history, and writes a clean `.zshrc` — without touching anything until a full backup is taken.

---

## Quick start

```bash
git clone https://github.com/amirrouh/dotlift.git
cd dotlift
# Edit config.yaml to match your preferences, then:
bash setup.sh
```

---

## What it does

| Step | Description |
|------|-------------|
| Backup | Saves all existing shell configs to `~/.dotlift-backup/<timestamp>` before making any changes |
| zsh | Installs zsh and sets it as your default shell |
| Oh My Zsh | Installs Oh My Zsh with your configured theme and plugins |
| CLI tools | Installs any combination of fzf, fd, ripgrep, eza, zoxide, bat, neovim, nvm, Rust, Homebrew, and more |
| Migration | Extracts bash aliases and exports and carries them into your new `.zshrc` |
| History | Converts `.bash_history` to zsh format, preserving timestamps |
| .zshrc | Generates a clean, well-organized `.zshrc` entirely from your config |

---

## Configuration

Everything is controlled through `config.yaml`. You never edit shell files by hand.

### Theme

```yaml
theme: robbyrussell   # any oh-my-zsh theme, or "powerlevel10k"
```

Set to `powerlevel10k` to auto-install Powerlevel10k. Run `p10k configure` after setup to customize the prompt.

### Editor

```yaml
editor: nvim   # vim | nano | micro | code
```

Sets `$EDITOR` and creates a `vim` alias pointing to nvim when neovim is chosen.

### Plugins

```yaml
plugins:
  - git
  - zsh-syntax-highlighting
  - zsh-autosuggestions
  - command-not-found
  - colored-man-pages
  - fzf
  - extract
```

Built-in oh-my-zsh plugins require no extra installation. Custom plugins listed under `custom_plugins` are cloned from git automatically.

### CLI tools

```yaml
tools:
  fzf: true        # fuzzy finder — Ctrl+R, Ctrl+T
  fd: true         # fast find replacement
  ripgrep: true    # fast grep replacement (rg)
  eza: true        # modern ls with icons and git status
  zoxide: true     # smart cd that learns your habits
  bat: true        # cat with syntax highlighting
  neovim: true     # modern vim
  nvm: true        # Node.js version manager
  rust: true       # Rust toolchain (rustup + cargo)
  homebrew: true   # Homebrew package manager
  xclip: true      # clipboard support (pbcopy / pbpaste)
  tree: true       # directory tree viewer
  nerd_font: true  # JetBrainsMono Nerd Font
```

Set any entry to `false` to skip it.

### Aliases and exports

```yaml
aliases:
  gs: "git status"
  gp: "git push"
  gl: "git log --oneline -20"

exports:
  GOPATH: "$HOME/go"
```

### Extra PATH entries

```yaml
extra_paths:
  - /usr/local/go/bin
  - $HOME/go/bin
```

### Raw zsh code

```yaml
extra_zshrc: |
  export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
  export PATH="$JAVA_HOME/bin:$PATH"
```

Appended verbatim to the end of `.zshrc`.

---

## Usage

```bash
bash setup.sh                       # automatic — installs all enabled tools
bash setup.sh --interactive         # prompt before each optional step
bash setup.sh --config ~/my.yaml    # use a custom config file
bash setup.sh --help                # show all options
```

---

## After setup

```bash
exec zsh          # start zsh in the current terminal

aa                # browse all aliases interactively with fzf
z <partial-dir>   # jump to a directory with zoxide
Ctrl+R            # fuzzy search through history
Ctrl+T            # fuzzy file search
```

---

## Supported distributions

| Distro family | Package manager |
|---|---|
| Ubuntu / Debian | apt |
| Fedora / RHEL / CentOS | dnf |
| Arch / Manjaro | pacman |
| openSUSE | zypper |
| Alpine | apk |

---

## Requirements

- Linux
- bash 4.0+
- curl
- sudo access for package installation

macOS is not supported — it already ships with zsh as the default shell.

---

## License

MIT
