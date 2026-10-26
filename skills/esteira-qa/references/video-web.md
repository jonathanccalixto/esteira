# Vídeo de cenário web (e de API sobre o palco)

O navegador da gravação é sempre um **Chrome limpo num display próprio** (Xephyr), nunca o
navegador nem a tela de quem usa a máquina. No macOS não há display próprio: o `chrome-limpo.sh`
sobe o Chrome **headless** e grava `QA_DISPLAY=headless` (veja [macOS](#macos-chrome-headless)).

## Subir, logar e preparar (fora da câmera)

```bash
SK=<pasta desta skill>; G=<pasta da rodada>
$SK/scripts/chrome-limpo.sh subir $G "$URL_INICIAL"
set -a; source $G/work/navegador.env; set +a       # QA_DISPLAY, CDP, GEOMETRIA (1440x900)
$SK/scripts/preparar-video.sh pasta $G/work        # playwright-core da gravação
```

- O app sob teste roda a partir da worktree do PR, em portas livres, do jeito que o projeto
  documenta (README, CLAUDE.md, Makefile, docker compose). Nunca em cima de algo que já rodava.
- Login pelo formulário, por script, com o usuário de teste; credencial em variável de ambiente.
- Navegação que recarrega a página perde instrumentação de `page.evaluate`: use
  `context.addInitScript` uma vez, na conexão do script da tomada.
- Antes da tomada: `document.fonts.ready`, recarregar e olhar um print.
- No ensaio, `page.on('response')` mostra quais chamadas a tela faz: elas dizem o que a fala pode
  afirmar sobre o backend.

## Tomada

```bash
qv () { python3 $SK/scripts/qa_video.py "$@"; }
cd $G/work
node $SK/scripts/tela-limpa.js $G/work/tela-limpa                       # só grava se sair 0
ffmpeg -y -loglevel error -f x11grab -framerate 30 -video_size $GEOMETRIA -i $QA_DISPLAY -c:v libx264 -preset ultrafast -pix_fmt yuv420p $G/work/video/bruto.mp4 > /dev/null 2>&1 &
echo $! > $G/work/video/rec.pid
qv marco --log $G/work/video/marcos.jsonl --tipo inicio
SK=$SK V=$G/work/video node demo.js                                     # cenas com demo-lib.js
qv marco --log $G/work/video/marcos.jsonl --tipo parar
kill -INT $(cat $G/work/video/rec.pid)
while kill -0 $(cat $G/work/video/rec.pid) 2>/dev/null; do sleep 0.3; done
node $SK/scripts/tela-limpa.js $G/work/tela-limpa                       # sujou? tomada descartada
```

`demo.js` usa `demo.iniciar({ video, display: QA_DISPLAY, cdp: CDP })` e `d.cena(id, ações,
preparo)`; cada cena dura ao menos a sua fala. Ações: `clicar`, `digitar`, `marcar`, `tecla`,
`apontar(alvo, { dx, dy })` (para o cursor parar ao lado de um número citado, sem cobri-lo).

Resposta diferente da esperada durante a tomada: o roteiro não fala o que não aconteceu. Isso é
achado; registre-o e decida se o vídeo mostra a falha.

Depois: `qv montar ...` e `qv conferir ...`, como em [vídeo narrado](video-narrado.md). Ao fim:
`$SK/scripts/chrome-limpo.sh descer $G`.

### macOS: Chrome headless

Com `QA_DISPLAY=headless` não existe display para o `x11grab`: quem grava é o próprio Chrome
(`gravar-cdp.js`, pelo screencast do CDP). Troque **só** as duas linhas do `ffmpeg` da tomada por:

```bash
node $SK/scripts/gravar-cdp.js $G/work/video/bruto.mp4 2> $G/work/video/gravar.log &
echo $! > $G/work/video/rec.pid
while [ ! -e $G/work/video/bruto.mp4.gravando ] && kill -0 $(cat $G/work/video/rec.pid) 2>/dev/null; do sleep 0.2; done
```

O resto é igual: `qv marco` de início depois disso, o `demo.js`, o marco de parar, `kill -INT` e a
espera até o processo sair (é nesse momento que ele monta o MP4). O cursor do vídeo é desenhado na
página pelo `demo-lib.js`, e o `tela-limpa.js` aprova direto (não há interface do navegador para
cobrir a página). Se o gravador sair antes da hora, veja `gravar.log`.

## App desktop ou outra interface

Mesmo princípio: um display próprio (Xvfb ou Xephyr) onde o app da worktree roda, `ffmpeg x11grab`
desse display, `xdotool` para mover o cursor, marcos com `qv marco` em volta das ações. Nunca a tela
da sessão do usuário. No macOS não há display isolado para app desktop: grave só o que roda no
Chrome headless e declare o restante da rodada sem vídeo, com o motivo. Android: emulador sem janela
(`-no-window`) e `adb shell screenrecord`, com a âncora visível descrita em
[vídeo narrado](video-narrado.md).
