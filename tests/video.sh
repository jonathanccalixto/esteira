#!/usr/bin/env bash
# Teste de ponta a ponta da tomada de vídeo do QA, do jeito que
# skills/esteira-qa/references/video-web.md manda fazer, em cada sistema:
#   Linux: Xephyr + Chrome limpo, cursor pelo xdotool, gravação por ffmpeg x11grab
#   macOS: Chrome headless, cursor desenhado pelo demo-lib.js, gravação pelo gravar-cdp.js
#
#   tests/video.sh
#
# Sem voz (as durações das falas são fixas): o que se testa é o navegador da
# rodada, o tela-limpa, o demo-lib e o gravador. Precisa de Chrome, ffmpeg, Node
# e, no Linux, Xephyr, xdpyinfo e xdotool. O Xephyr abre a sua janela num
# display que já exista: na CI, rode dentro do xvfb-run.
set -uo pipefail
raiz=$(cd "$(dirname "$0")/.." && pwd)
SK=$raiz/skills/esteira-qa
tmp=$(mktemp -d)
G=$tmp/rodada
V=$G/work/video
desce () { "$SK/scripts/chrome-limpo.sh" descer "$G" > /dev/null 2>&1; rm -rf "$tmp"; }
trap desce EXIT
morre () {
  local logs=
  for l in "$tmp"/*.log "$G"/work/*.log "$V"/*.log; do [[ -s $l ]] && logs+="--- ${l##*/}"$'\n'"$(tail -20 "$l")"$'\n'; done
  echo "FALHA $*"; printf '%s' "$logs"
  # Na CI, a falha (com o fim dos logs da rodada) vira anotação: aparece no resumo do PR.
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    # Escapes do GitHub para mensagem de várias linhas; sem aspas no padrão (o bash 3.2 as mantém).
    local nl=$'\n' cr=$'\r'
    msg="$*$nl$logs"; msg=${msg//\%/%25}; msg=${msg//$cr/%0D}; msg=${msg//$nl/%0A}
    echo "::error title=vídeo do QA ($(uname -s))::$msg"
  fi
  exit 1
}
ok () { echo "ok    $*"; }
qv () { python3 "$SK/scripts/qa_video.py" "$@"; }

echo "sistema: $(uname -s) · bash $BASH_VERSION · node $(node -v)"

# Uma página que muda de cor ao clicar: o vídeo tem de mostrar o antes e o depois.
cat > "$tmp/pagina.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>tomada</title>
<style>body{margin:0;height:100vh;display:grid;place-items:center;background:#1e3a8a;font:24px sans-serif}
button{font-size:28px;padding:16px 32px}</style>
<button id="b" onclick="document.body.style.background='#15803d';this.textContent='clicado'">clicar</button>
HTML

# 1. Subir, preparar (fora da câmera)
out=$("$SK/scripts/chrome-limpo.sh" subir "$G" "file://$tmp/pagina.html" 800x600 2> "$tmp/subir.log") || morre "chrome-limpo.sh subir"
ok "chrome-limpo.sh subir: $out"
set -a; source "$G/work/navegador.env"; set +a
"$SK/scripts/preparar-video.sh" pasta "$G/work" > /dev/null || morre "preparar-video.sh pasta"
mkdir -p "$V/narracao"
echo '{"abrir": 1.0, "clicar": 1.5}' > "$V/narracao/duracoes.json"
cat > "$G/work/demo.js" <<'JS'
const demo = require(`${process.env.SK}/scripts/demo-lib.js`)
;(async () => {
  const d = await demo.iniciar({ video: process.env.V, display: process.env.QA_DISPLAY, cdp: process.env.CDP })
  await d.cena('abrir', async () => {})
  await d.cena('clicar', async () => { await d.clicar('#b') })
  const texto = await d.page.textContent('#b')
  await d.fim()
  if (texto !== 'clicado') { console.error(`o clique não chegou na página: "${texto}"`); process.exit(1) }
})().catch(e => { console.error(e); process.exit(1) })
JS

# 2. Tomada
cd "$G/work"
node "$SK/scripts/tela-limpa.js" "$G/work/tela-limpa" > "$tmp/limpa.json" || morre "tela-limpa.js antes: $(cat "$tmp/limpa.json")"
ok "tela-limpa.js: $(cat "$tmp/limpa.json")"
if [[ $QA_DISPLAY == headless ]]; then
  node "$SK/scripts/gravar-cdp.js" "$V/bruto.mp4" 2> "$V/gravar.log" &
  echo $! > "$V/rec.pid"
  while [ ! -e "$V/bruto.mp4.gravando" ] && kill -0 "$(cat "$V/rec.pid")" 2>/dev/null; do sleep 0.2; done
  [[ -e $V/bruto.mp4.gravando ]] || morre "gravar-cdp.js saiu antes de começar"
else
  ffmpeg -y -loglevel error -f x11grab -framerate 30 -video_size "$GEOMETRIA" -i "$QA_DISPLAY" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$V/bruto.mp4" 2> "$V/ffmpeg.log" &
  echo $! > "$V/rec.pid"
  sleep 1
fi
qv marco --log "$V/marcos.jsonl" --tipo inicio > /dev/null
SK=$SK V=$V node demo.js > "$V/demo.log" 2>&1 || morre "demo.js"
ok "demo-lib.js: o cursor foi até o botão e o clique chegou na página"
qv marco --log "$V/marcos.jsonl" --tipo parar > /dev/null
kill -INT "$(cat "$V/rec.pid")"
while kill -0 "$(cat "$V/rec.pid")" 2>/dev/null; do sleep 0.3; done

# 3. O vídeo abre, tem a duração da tomada e mostra a página mudando
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V/bruto.mp4") || morre "o vídeo não abre"
python3 -c "import sys; sys.exit(0 if float('$dur') >= 2.5 else 1)" || morre "vídeo curto demais: ${dur}s (a tomada durou mais de 2,5 s)"
ok "vídeo: ${dur}s"
ffmpeg -loglevel error -y -i "$V/bruto.mp4" -vf "select=eq(n\,0)" -frames:v 1 -f rawvideo -pix_fmt gray "$tmp/primeiro.raw"
ffmpeg -loglevel error -y -sseof -0.3 -i "$V/bruto.mp4" -frames:v 1 -f rawvideo -pix_fmt gray "$tmp/ultimo.raw"
cmp -s "$tmp/primeiro.raw" "$tmp/ultimo.raw" && morre "o primeiro e o último quadro são iguais: o vídeo não pegou o clique"
ok "vídeo: o primeiro e o último quadro diferem (a página mudou durante a gravação)"
echo
echo "tudo certo"
