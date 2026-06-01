#!/bin/bash
# =========================================================
# SERVEUR D'ARCHIVES (Clean Logs)
# =========================================================

if [ $# -ne 1 ]; then
    echo "usage: $(basename $0) PORT"
    exit 1
fi

PORT="$1"
ARCHIVE_DIR="./archives"
mkdir -p "$ARCHIVE_DIR"

FIFO="/tmp/$USER-fifo-$$"
function nettoyage() { rm -f "$FIFO"; }
trap nettoyage EXIT
[ -e "$FIFO" ] || mkfifo "$FIFO"

# --- COMMANDS ---

function commande-non-comprise () {
   echo "[LOG] Erreur: Commande inconnue $1" >&2
}

function commande-LIST() {
    echo "[LOG] LIST request" >&2
    # Only ls output goes to stdout (pipe)
    ls -1 "$ARCHIVE_DIR"
}

function commande-GET() {
    local fichier="$1"
    echo "[LOG] GET request for $fichier" >&2
    if [ -f "$ARCHIVE_DIR/$fichier" ]; then
        # Only file content goes to stdout (pipe)
        cat "$ARCHIVE_DIR/$fichier"
    else
        echo "ERROR" >&2
    fi
}

function commande-PUT() {
    local fichier="$1"
    echo "[LOG] PUT request for $fichier" >&2
    # Read stdin to file
    cat > "$ARCHIVE_DIR/$fichier"
}

# --- LOOPS ---

function interaction() {
    local cmd args
    while read cmd args; do
        fun="commande-$cmd"
        if [ "$(type -t $fun)" = "function" ]; then
            $fun $args
        else
            commande-non-comprise $cmd $args
        fi
    done
}

function accept-loop() {
    echo "[SERVER] En attente sur le port $PORT..." >&2
    while true; do
        # Interaction input comes from FIFO, Output goes to NC -> FIFO
        interaction < "$FIFO" | nc -l -p "$PORT" > "$FIFO"
        sleep 0.1
    done
}

accept-loop