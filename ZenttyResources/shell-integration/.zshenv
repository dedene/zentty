# vim:ft=zsh

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${ZENTTY_ORIGINAL_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$ZENTTY_ORIGINAL_ZDOTDIR"
    builtin unset ZENTTY_ORIGINAL_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    builtin typeset _zentty_user_zshenv="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_zentty_user_zshenv" ]] || builtin source -- "$_zentty_user_zshenv"
} always {
    if [[ -o interactive && "${ZENTTY_SHELL_INTEGRATION:-1}" != "0" && -n "${ZENTTY_SHELL_INTEGRATION_DIR:-}" ]]; then
        builtin typeset _zentty_integration="$ZENTTY_SHELL_INTEGRATION_DIR/zentty-zsh-integration.zsh"
        [[ ! -r "$_zentty_integration" ]] || builtin source -- "$_zentty_integration"
    fi

    builtin unset _zentty_user_zshenv _zentty_integration
}
