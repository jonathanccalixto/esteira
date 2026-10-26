#!/usr/bin/env bash
# Testes de fumaça do pipeline no Linux e no macOS: o que depende do sistema
# (travas, prazo, limpeza de processos, RAM livre, painel de status) roda de
# verdade numa cópia descartável de pipeline/, sem Herdr, sem GitHub.
#
#   tests/portabilidade.sh
#
# No macOS a CI roda com /bin/bash, o 3.2 do sistema, de propósito: é ele que
# os scripts encontram numa máquina sem o bash do Homebrew. Nada de bash 4 aqui.
set -uo pipefail
raiz=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
falhas=0
ok () { echo "ok    $*"; }
erro () { echo "FALHA $*"; falhas=$((falhas + 1)); }
confere () { local nome=$1; shift; if "$@"; then ok "$nome"; else erro "$nome"; fi; }

echo "sistema: $(uname -s) · bash $BASH_VERSION · $(python3 --version)"

# Cópia do pipeline como o bootstrap instala (.claude/esteira/), com um config mínimo.
p=$tmp/projeto/.claude/esteira
mkdir -p "$p"
cp -R "$raiz/skills/esteira-bootstrap/pipeline/bin" "$p/bin"
state=$tmp/estado; wt=$tmp/worktrees
mkdir -p "$state" "$wt"
cat > "$p/config.json" <<EOF
{"repo": "dono/repo", "state_dir": "$state", "worktrees_dir": "$wt", "max_workers": 4,
 "timeouts": {}, "min_free_ram_gb": 4, "monitors": false,
 "stages": {"dev": {"queue": "Dev queue", "active": "In development", "skill": "esteira-dev",
                    "next": "Review queue", "max": 1, "space": "dev"}}}
EOF
bin=$p/bin

# --- flock.py: o substituto do util-linux, testado mesmo onde o flock existe ---
exec 8>"$state/t.lock"
"$bin/flock.py" 8
( exec 9>"$state/t.lock"; "$bin/flock.py" -w 1 9 ); rc=$?
confere "flock.py: trava ocupada desiste com 1 (deu $rc)" test "$rc" = 1
exec 8>&-
( exec 9>"$state/t.lock"; "$bin/flock.py" -w 1 9 ); rc=$?
confere "flock.py: trava livre pega com 0 (deu $rc)" test "$rc" = 0

# --- lock.sh: o caminho que o sistema escolher (flock real ou flock.py) ---
out=$("$bin/lock.sh" teste sh -c 'cat "$1"' _ "$state/teste.owner" 2>&1)
confere "lock.sh: roda o comando e grava o dono" grep -q '"cmd"' <<<"$out"
confere "lock.sh: apaga o dono no fim" test ! -e "$state/teste.owner"
"$bin/lock.sh" segura sleep 3 &
sleep 1
out=$(python3 - "$bin" "$state" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import status
print(status.lock_owner("segura"))
PY
)
confere "status.py: trava em uso aparece como em uso ($out)" grep -q '^em uso' <<<"$out"
wait

# --- prazo.sh: estouro sai 124, senão o código do próprio comando ---
"$bin/prazo.sh" 1 sleep 5; rc=$?
confere "prazo.sh: estouro sai 124 (deu $rc)" test "$rc" = 124
"$bin/prazo.sh" 5 sh -c 'exit 7'; rc=$?
confere "prazo.sh: repassa o código do comando (deu $rc)" test "$rc" = 7
# Sem timeout nem gtimeout no PATH: o substituto em Python.
mkdir -p "$tmp/path"
for b in bash env python3 sleep sh; do ln -s "$(command -v $b)" "$tmp/path/$b"; done
PATH=$tmp/path "$bin/prazo.sh" 1 sleep 5; rc=$?
confere "prazo.sh (Python): estouro sai 124 (deu $rc)" test "$rc" = 124
PATH=$tmp/path "$bin/prazo.sh" 5 sh -c 'exit 7'; rc=$?
confere "prazo.sh (Python): repassa o código (deu $rc)" test "$rc" = 7

# --- cleanup.sh: mata o que roda dentro da worktree da issue, e só isso ---
mkdir -p "$wt/dev-42" "$tmp/fora"
(cd "$wt/dev-42" && exec sleep 300) & dentro=$!
(cd "$tmp/fora" && exec sleep 300) & fora=$!
sleep 1
out=$(USER=${USER:-$(id -un)} "$bin/cleanup.sh" dev 42)
echo "$out" | sed 's/^/      /'
sleep 1
confere "cleanup.sh: parou o processo da worktree" sh -c "! kill -0 $dentro 2>/dev/null"
confere "cleanup.sh: não tocou no processo de fora" kill -0 "$fora"
kill "$fora" 2>/dev/null

# --- lib.free_ram_gb: /proc/meminfo no Linux, vm_stat no macOS ---
gb=$(python3 -c "import sys; sys.path.insert(0, '$bin'); import lib; print(lib.free_ram_gb())")
confere "free_ram_gb: número positivo ($gb GB)" python3 -c "import sys; sys.exit(0 if float('$gb') > 0 else 1)"

# --- status.py: loops achados pelo caminho completo (o BSD ps corta sem -ww) ---
sh -c 'sleep 30; true' "$bin/dispatch.py" dev --loop &
sleep 1
out=$(python3 -c "import sys; sys.path.insert(0, '$bin'); import status; print(status.loops())")
confere "status.py: acha o loop pelo caminho completo ($out)" grep -q "'dispatch dev': True" <<<"$out"

# --- bash 3.2: o `bash -n` não pega o que só falha ao expandir (${b,,} dá "bad
#     substitution" na hora de rodar), então os recursos do bash 4 são barrados aqui ---
# Comentários ficam de fora (um "# não ${b,,}" explicando a troca não é uso).
bash4=$(cd "$raiz" && awk '{ sub(/(^|[ \t])#.*/, ""); print FILENAME ":" FNR ": " $0 }' install.sh $(find skills -name '*.sh') \
  | grep -E '\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}|declare -A|local -A|mapfile|readarray|&>>|;;&|\$\{[A-Za-z_]+@[QEPAa]\}')
confere "nenhum recurso de bash 4 nos .sh${bash4:+: $bash4}" test -z "$bash4"

echo
if (( falhas )); then echo "$falhas falha(s)"; exit 1; fi
echo "tudo certo"
