# bash completion for salvage
#
# Install: source this file, or place it in a bash-completion completions dir.

_salvage() {
    local cur prev opts
    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}

    opts="-r --reference --exclude --absolute --print0 --all --no-rollup
          -p --paranoid --no-default-excludes --exclude-hidden --json
          --save-scan -v --verbose -q --quiet --no-color -h --help --version"

    case $prev in
        -r|--reference)
            compopt -o dirnames 2>/dev/null
            COMPREPLY=()
            return 0 ;;
        --json|--save-scan)
            compopt -o default 2>/dev/null
            COMPREPLY=()
            return 0 ;;
        --exclude)
            return 0 ;;
    esac

    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
        return 0
    fi

    compopt -o dirnames 2>/dev/null
    COMPREPLY=()
    return 0
}

complete -F _salvage salvage
