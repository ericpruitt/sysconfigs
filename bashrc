#!/usr/bin/env bash

# The user profile and bashrc contain circular references to one another
# because different forms of accessing the system lead to different loading
# behaviors (an "*" indicates only part of the file is executed):
#
#   ssh $LOGNAME@$HOSTNAME:              ~/.profile -> ~/.bashrc
#   ssh $LOGNAME@$HOSTNAME "command...": ~/.bashrc* -> ~/.profile
#   X11 Session:                         ~/.profile
#   └─> GUI Terminal Emulator:           ~/.bashrc
#
# Since the profile modifies the PATH environment variable, it is always
# loaded, but the entirety of the bashrc is only loaded when Bash is running as
# an interactive shell.
test "$PROFILE_INCLUDE_GUARD" || source "$HOME/.profile" 2>&-

# The rest of this file should only be loaded for interactive sessions.
test "$PS1" || return 0

# Integral representation of Bash version useful for conditionally using
# features associated with certain versions of Bash.
#
# Work-arounds for the following issues are implemented using this variable:
#
# - In Bash 4.3 and lower, "set -o nounset" breaks autocompletion:
#   <https://lists.gnu.org/archive/html/bug-bash/2016-04/msg00090.html>
declare -r BASH_MAJOR_MINOR="$((BASH_VERSINFO[0] * 1000 + BASH_VERSINFO[1]))"

# Define various command aliases.
#
function define-aliases()
{
    alias awk='paginate awk --'
    alias back='test -z "${OLDPWD:-}" || cd "$OLDPWD"'
    alias cat='paginate cat --'
    alias cp='cp -p -R'
    alias df='paginate df -- -h'
    alias diff='paginate diff -- -u'
    alias dpkg-query='paginate dpkg-query --'
    alias du='paginate du -- -h'
    alias egrep='grep -E'
    alias fgrep='grep -F'
    alias find='paginate find --'
    alias gawk='paginate gawk --'
    alias grep='paginate grep --'
    alias head='head -n "$((LINES - 1))"'
    alias help='paginate help --'
    alias history='paginate history --'
    alias info='info --vi-keys'
    alias ldd='paginate ldd --'
    alias ls='COLUMNS="$COLUMNS" paginate ls -C -A -F -h'
    alias make='gmake'
    alias man='man --no-hyphenation'
    alias mtr='mtr -t'
    alias otr='HISTFILE=/dev/null bash'
    alias paragrep='LC_ALL=C paginate paragrep -T -B1 -n'
    alias ps='paginate ps --'
    alias pstree='paginate pstree -- -a -p -s -U'
    alias readelf='paginate readelf --'
    alias reset='tput reset'
    alias screen='SHLVL_OFFSET= screen'
    alias sed='paginate sed --'
    alias shred='shred -n 0 -v -u -z'
    alias sort='paginate sort --'
    alias strings='paginate strings --'
    alias tac='paginate tac --'
    alias tail='tail -n "$((LINES - 1))"'
    alias tmux='SHLVL_OFFSET= tmux'
    alias tr='paginate tr --'
    alias tree='paginate tree -C -a -I ".git|__pycache__|lost+found"'
    alias vi='vim'
    alias xargs='paginate xargs --'
    alias xxd='paginate xxd --'

    # This alias is used to allow the user to execute a command without adding
    # it to the shell history by prefixing it with "silent".
    alias silent=''

    case "$OSTYPE" in
      *linux*)
        alias ps='paginate ps --cols=$COLUMNS --sort=uid,pid -N \
                      --ppid 2 -p 2'
      ;&
      *cygwin*|*msys*|*gnu*)
        alias cp='cp -a -v'
        alias grep='paginate grep --color=always'
        alias ls='paginate ls "-C -w $COLUMNS --color=always" -b -h \
                      -I lost+found -I __pycache__'
        alias rm='rm -v'
      ;;
    esac
}

# Disable aliases for commands that are not present on this system, and compact
# multi-line aliases into a single line.
#
function prune-aliases()
{
    local alias_key
    local alias_value
    local argv

    for alias_key in "${!BASH_ALIASES[@]}"; do
        alias_value="${BASH_ALIASES[$alias_key]//\\$'\n'+(\ )/}"
        argv=($alias_value)
        # Ignore environment variables and the paginate function.
        while [[ "${argv[0]}" =~ ^([a-zA-Z_]+[a-zA-Z0-9_]*=|paginate$) ]]; do
            argv=(${argv[@]:1})
        done
        test "${#argv[@]}" -gt 0 || continue
        ! hash -- "${argv[0]}" 2>&- && unalias "$alias_key" && continue
        BASH_ALIASES[$alias_key]="${alias_value}"
    done
}

# Paginate arbitrary commands when stdout is a TTY. If stderr is attached to a
# TTY, data written to it will also be sent to the pager. Just because stdout
# and stderr are both TTYs does not necessarily mean it is the same terminal,
# but in practice, this is rarely a problem.
#
#   $1  Name or path of the command to execute.
#   $2  White-space separated list of options to pass to the command when
#       stdout is a TTY. If there are no TTY-dependent options, this should be
#       "--".
#   $@  Arguments to pass to command.
#
function paginate()
{
    local errfd=1

    local command="$1"
    local tty_specific_args="$2"
    shift 2

    if [[ -t 1 ]]; then
        test "$tty_specific_args" != "--" || tty_specific_args=""
        test -t 2 || errfd=2
        "$command" $tty_specific_args "$@" 2>&"$errfd" | less -X -F -R
        return "${PIPESTATUS[0]/141/0}"  # Ignore SIGPIPE failures.
    fi

    "$command" "$@"
}

# Launch a background command detached from the current terminal session.
#
#   $1  Command
#   $@  Command arguments
#
function spawn()
{
    local command="${1:-}"

    if [[ -z "$command" ]]; then
        echo "usage: spawn COMMAND [ARGUMENT...]"
        return 1
    elif ! hash -- "$command" 2>&-; then
        echo "spawn: $command: command not found" >&2
        return 127
    fi

    setsid "$@" < /dev/null &> /dev/null
}

# Update the Bash prompt and display the exit status of the previously executed
# command if it was non-zero. The prompt has the following indicators:
#
# - Show nesting depth of interactive shells when greater than 1.
# - When accessing the host over SSH, include username and hostname.
# - If there are background jobs, show the quantity in brackets.
# - Terminate the prompt with "#" when running as root and "$" otherwise.
#
# Any variables that are all lower case (`/^[a-z][a-z0-9_]*$/`) are unset if
# they are not exported.
#
function -prompt-command()
{
    local exit_status="${debug_hook_ran:+$?}"

    local _saved_vars
    local var

    local depth="$((SHLVL - SHLVL_OFFSET + 1))"
    local jobs="$(jobs)"

    test "${exit_status:=0}" -eq 0 || echo -e "($exit_status)\a"
    test "$depth" -gt 1 || depth=""

    PS1="${depth:+$depth: }${SSH_TTY:+\\u@\\h:}\\W${jobs:+ [\\j]}\\$ "

    _saved_vars="$(compgen -e)"
    _saved_vars="^(${_saved_vars//$'\n'/|}|[^a-z].*|.*[^a-z0-9_].*)\$"

    for var in $(compgen -v); do
        if ! [[ "$var" =~ $_saved_vars ]]; then
            unset "$var"
        fi
    done

    # Send SIGWINCH to the shell to refresh COLUMNS and LINES in case a signal
    # from the terminal emulator was intercepted by a foreground process.
    kill -SIGWINCH $$

    # Prevent Ctrl-Z from sending SIGTSTP when entering commands so it can be
    # remapped with readline. When Bash uses job control in debug hooks, it can
    # produce in some racy, quirky behavior, so stty is run inside of a command
    # substitution which avoids the parent shell's job control.
    $(stty susp undef)
    _susp_undef="x"

    test "$BASH_MAJOR_MINOR" -ge 4004 || set +u
}

# Hook executed before every Bash command that is not run inside a subshell or
# function. When using a supported terminal emulator, the title will be set to
# the last executed command.
#
#   $1  Last executed command.
#
function -debug-hook()
{
    local alias_key
    local guess

    local command="$1"
    local search_again="x"
    local shortest_guess="$command"

    # Remap Ctrl+Z to SIGTSTP before executing a command. Refer to the
    # complementary comment in the -debug-hook function.
    test -n "${_susp_undef:-}" && unset _susp_undef && $(stty susp "^Z")

    test "$BASH_MAJOR_MINOR" -ge 4004 || set -u
    test "$command" != "$PROMPT_COMMAND" || return 0

    if [[ "${TERM:-}" =~ ^(tmux|xterm|screen|rxvt|st(-*)?$) ]]; then
        # Iterate over all aliases and figure out which ones were likely used
        # to create the command. The looping handles recursive aliases.
        while [[ "${search_again:-}" ]]; do
            unset search_again
            for alias_key in "${!BASH_ALIASES[@]}"; do
                guess="${command/#${BASH_ALIASES[$alias_key]}/$alias_key}"
                test "${#guess}" -lt "${#shortest_guess}" || continue
                shortest_guess="$guess"
                search_again="x"
            done
            command="$shortest_guess"
        done

        printf "\033]2;%s\033\\" "${SSH_TTY:+$LOGNAME@$HOSTNAME: }$command"
    fi

    debug_hook_ran="x"
}

# Bootstrap function to configure various settings and launch tmux when it
# appears that Bash is not already running inside of another multiplexer.
#
function setup()
{
    unset setup

    complete -r
    complete -d cd
    shopt -s autocd
    shopt -s cdspell
    shopt -s cmdhist
    shopt -s dirspell
    shopt -s extglob
    shopt -s histappend

    # Setup exit hook to preserve splits when exiting a shell in a pane.
    if [[ "${TMUX:-}" ]]; then
        hash metamux 2>&- && trap 'metamux shell-exit-hook "$PPID"' EXIT

    # Automatically start tmux if the shell is not being run within a
    # multiplexer or console.
    elif [[ ! "${TERM:-}" =~ ^(tmux|screen|linux$|vt[0-9]+) ]]; then
        hash tmux 2>&- && SHLVL_OFFSET= tmux new -A -s 0 && exit
    fi

    # If running inside of tmux, make sudo default to using TERM=screen, and if
    # the host does not have a terminfo entry for tmux, fall back to using
    # TERM=screen for everything.
    if [[ "${TERM:-}" =~ ^tmux ]]; then
        if tput -T "$TERM" longname &> /dev/null; then
            alias sudo='TERM="screen" sudo'
        else
            export TERM="screen"
        fi
    fi

    HISTFILESIZE="2147483647"
    HISTIGNORE="history?( -[acdnrw]*):@(help|history)?( ):@(fg|silent|otr) *"
    HISTSIZE="2147483647"
    HISTTIMEFORMAT=""
    PROMPT_COMMAND="-prompt-command"

    define-aliases && prune-aliases

    # Disable output flow control; makes ^Q and ^S usable.
    stty -ixon -ixoff

    # Secondary bashrc for machine-specific settings.
    source "$HOME/.local.bashrc" 2>&-

    test "$BASH_MAJOR_MINOR" -lt 4004 || set -u
    test "${SHLVL_OFFSET:-}" || export SHLVL_OFFSET="$SHLVL"
    test "$(trap -p DEBUG)" || trap '\-debug-hook "$BASH_COMMAND"' DEBUG
}

setup
