// Gravação da tomada quando o Chrome da rodada é headless (macOS: QA_DISPLAY=headless). Faz o papel do
// `ffmpeg -f x11grab` do Linux, que lá grava o display Xephyr: aqui não há display para gravar, então
// os quadros vêm do próprio Chrome pelo CDP (Page.startScreencast) e o ffmpeg só monta o MP4 no fim.
//
//   cd $G/work && node $SK/scripts/gravar-cdp.js $G/work/video/bruto.mp4 &
//   echo $! > $G/work/video/rec.pid
//   while [ ! -e $G/work/video/bruto.mp4.gravando ]; do sleep 0.2; done     # só então o marco de início
//   ...
//   kill -INT $(cat $G/work/video/rec.pid)        # como no Linux: SIGINT e esperar o processo sair
//
// Mesmo contrato do ffmpeg da tomada: sem áudio, H.264 yuv420p a 30 qps, e o instante zero do vídeo é o
// relógio de parede em que a captura começou (é contra ele que o `qa_video.py` alinha os marcos). O
// screencast só manda quadro quando a página muda de desenho; cada quadro fica na tela até o seguinte,
// pelos carimbos de tempo do próprio Chrome, então tela parada continua no vídeo com a duração certa.
// Usa o CDP e a GEOMETRIA do navegador.env e o playwright-core da rodada ($G/work/node_modules).
'use strict'
const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd()] }))

const saida = path.resolve(process.argv[2] || '')
if (!process.argv[2]) { console.error('uso: node gravar-cdp.js <saida.mp4>'); process.exit(2) }
const [largura, altura] = (process.env.GEOMETRIA || '1440x900').split('x').map(Number)
const quadros = `${saida}.quadros`
const sinal = `${saida}.gravando`
const aspas = (p) => `'${p.replace(/'/g, "'\\''")}'`   // aspas do ffconcat

;(async () => {
  fs.rmSync(quadros, { recursive: true, force: true })
  fs.mkdirSync(quadros, { recursive: true })
  const browser = await chromium.connectOverCDP(process.env.CDP || 'http://127.0.0.1:9222')
  const context = browser.contexts()[0]
  const page = context.pages()[0] || await context.newPage()
  const cdp = await context.newCDPSession(page)
  const lista = []   // { arquivo, t } com t em segundos de relógio de parede
  let inicio = null
  let parando = false

  cdp.on('Page.screencastFrame', ({ data, metadata, sessionId }) => {
    cdp.send('Page.screencastFrameAck', { sessionId }).catch(() => {})
    if (parando) return
    const arquivo = path.join(quadros, `${String(lista.length).padStart(7, '0')}.jpg`)
    fs.writeFileSync(arquivo, Buffer.from(data, 'base64'))
    lista.push({ arquivo, t: metadata.timestamp || Date.now() / 1000 })
  })

  inicio = Date.now() / 1000
  await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 92, maxWidth: largura, maxHeight: altura, everyNthFrame: 1 })
  fs.writeFileSync(sinal, String(inicio))

  async function parar () {
    if (parando) return
    parando = true
    const fim = Date.now() / 1000
    await cdp.send('Page.stopScreencast').catch(() => {})
    await browser.close().catch(() => {})   // conexão por CDP: só desconecta, o Chrome continua
    try {
      if (!lista.length) throw new Error('o Chrome não mandou nenhum quadro')
      // Lista do demuxer concat: cada quadro dura até o seguinte; o primeiro cobre desde o início
      // da captura, e o último vai até o SIGINT. O último é repetido porque o concat ignora a
      // duração da última entrada.
      const linhas = ['ffconcat version 1.0']
      lista.forEach((q, i) => {
        const de = i === 0 ? inicio : q.t   // o zero do vídeo é sempre o início da captura
        const ate = i + 1 < lista.length ? lista[i + 1].t : fim
        linhas.push(`file ${aspas(q.arquivo)}`, `duration ${Math.max(0.001, ate - de).toFixed(6)}`)
      })
      linhas.push(`file ${aspas(lista[lista.length - 1].arquivo)}`)
      const concat = path.join(quadros, 'lista.ffconcat')
      fs.writeFileSync(concat, linhas.join('\n') + '\n')
      execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-nostdin', '-f', 'concat', '-safe', '0', '-i', concat,
        '-vf', `fps=30,scale=${largura}:${altura}:force_original_aspect_ratio=decrease,pad=${largura}:${altura}:(ow-iw)/2:(oh-ih)/2,format=yuv420p`,
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', saida], { stdio: 'inherit' })
      fs.rmSync(quadros, { recursive: true, force: true })
      fs.rmSync(sinal, { force: true })
      process.exit(0)
    } catch (e) {
      console.error(`gravar-cdp: ${e.message}; quadros mantidos em ${quadros}`)
      process.exit(1)
    }
  }
  process.on('SIGINT', parar)
  process.on('SIGTERM', parar)
})().catch(e => { console.error(`gravar-cdp: ${e.message || e}`); process.exit(2) })
