# ~/.zshrc — installed by pi-bootstrap (https://github.com/prithivirajasingh5/pi-bootstrap)
# Re-running bootstrap.sh replaces this file (the previous one is backed up to ~/.zshrc.bak.<time>).
# Put personal additions in ~/.zshrc.local instead; it is sourced at the end and never overwritten.

# ---- options ----------------------------------------------------------------
setopt autocd interactivecomments magicequalsubst nonomatch notify numericglobsort promptsubst
WORDCHARS=${WORDCHARS//\/}          # Ctrl+W stops at '/'
PROMPT_EOL_MARK=""                  # no '%' at the end of output without a trailing newline

# ---- history ----------------------------------------------------------------
HISTFILE=~/.zsh_history
HISTSIZE=120000     # commands kept in memory for this shell
SAVEHIST=100000     # commands written to ~/.zsh_history
# HISTSIZE > SAVEHIST leaves room for duplicates, so hist_expire_dups_first (below) can drop
# old duplicates before unique commands once history is full (zsh docs recommend this).
setopt hist_expire_dups_first hist_ignore_dups hist_ignore_space hist_verify share_history

# ---- key bindings (emacs style + the usual extras) ---------------------------
bindkey -e
bindkey ' ' magic-space                       # expand !history on space
bindkey '^[[1;5C' forward-word                # Ctrl+Right
bindkey '^[[1;5D' backward-word               # Ctrl+Left
bindkey '^[[3~' delete-char                   # Delete
bindkey '^[[H' beginning-of-line              # Home
bindkey '^[[F' end-of-line                    # End
bindkey '^[[Z' reverse-menu-complete          # Shift+Tab

# ---- completion ---------------------------------------------------------------
autoload -Uz compinit
mkdir -p ~/.cache
compinit -d ~/.cache/zcompdump
zstyle ':completion:*' menu select                                 # arrow-key menu
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'          # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.cache/zsh

# ---- colours & aliases ------------------------------------------------------------
if command -v dircolors >/dev/null; then eval "$(dircolors -b)"; fi
alias ls='ls --color=auto'
alias ll='ls -l'
alias la='ls -A'
alias l='ls -alh'
alias grep='grep --color=auto'
alias ip='ip --color=auto'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}"'

# ---- prompt (same look as the laptop) ----------------------------------------------
#   ┌──(pi@opi)-[~/docker]
#   └─$                                    exit code ⨯ / background jobs ⚙ on the right
PROMPT=$'%F{%(#.red.green)}┌──(%B%F{%(#.red.green)}%n@%m%b%F{%(#.red.green)})-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.red.green)}]\n└─%B%(#.%F{red}#.%F{green}$)%b%F{reset} '
RPROMPT=$'%(?.. %? %F{red}%B⨯%b%F{reset})%(1j. %j %F{yellow}%B⚙%b%F{reset}.)'

# ---- plugins (Debian packages; syntax-highlighting must be sourced last) ------------
if [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    . /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#777'          # grey ghost text; → or End accepts it
fi

[ -f ~/.zshrc.local ] && . ~/.zshrc.local

if [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    . /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
    ZSH_HIGHLIGHT_STYLES[default]=none
    ZSH_HIGHLIGHT_STYLES[unknown-token]=fg=red,bold     # typo'd command turns red
    ZSH_HIGHLIGHT_STYLES[path]=underline
fi
