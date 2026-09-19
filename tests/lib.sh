# Shared fixtures: a fake orca on PATH and a tiny scratch repo.
TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GATE="$TESTS_DIR/../skills/worktree-gate/scripts/gate.sh"
GIT_ID=(-c user.name=test -c user.email=test@example.com)

mkshim() { # <dir> <managed|unmanaged|hang>
    mkdir -p "$1/bin"
    echo "$2" > "$1/mode"
    : > "$1/orca.log"
    # Symlink, not copy: macOS scans every new executable on first run (~1s each).
    ln -s "$TESTS_DIR/fake-orca" "$1/bin/orca"
}

mkrepo() { # <dir> [feature] -> <dir>/repo on main, or on add-name-flag with one commit
    mkdir -p "$1/repo"
    (
        cd "$1/repo" || exit 1
        git init -q -b main .
        printf 'import sys\n\ndef main():\n    print("hello")\n\nif __name__ == "__main__":\n    main()\n' > greet.py
        printf '# greet\n\nRun: uv run greet.py\n' > README.md
        git add .
        git "${GIT_ID[@]}" commit -q -m "init greet cli"
        if [ "${2:-}" = feature ]; then
            git checkout -q -b add-name-flag
            printf 'import argparse\n\ndef main():\n    p = argparse.ArgumentParser()\n    p.add_argument("--name", default="")\n    a = p.parse_args()\n    print(f"hello {a.name}".strip())\n\nif __name__ == "__main__":\n    main()\n' > greet.py
            git "${GIT_ID[@]}" commit -qam "add --name flag to greet"
        fi
    )
}
