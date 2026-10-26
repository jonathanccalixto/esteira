// Apoio do roteiro de demonstração narrada do QA BOT. Roda no host, conectado por CDP ao Chrome em modo
// quiosque aberto no display PRÓPRIO da rodada (Xephyr), nunca no display da sessão do usuário. No macOS
// (QA_DISPLAY=headless) o Chrome é headless e o cursor é desenhado na página.
// O script da demonstração fica em $RUN/work/, onde está o playwright-core da rodada:
//
//   const demo = require('<pasta da skill>/scripts/demo-lib.js')
//   const d = await demo.iniciar({ video: process.env.V, display: process.env.QA_DISPLAY, cdp: 'http://127.0.0.1:<porta>' })
//   await d.cena('abertura', async () => { await d.page.goto(`${process.env.BASE}/agendamento`) })
//   await d.cena('salvar', async () => { await d.clicar('[type=submit]') }, async () => { await d.digitar('#campo', 'texto') })
//   await d.fim()
//
// Cada cena grava o marco de início (o mesmo formato do `qa_video.py marco`) e dura pelo menos a fala dela
// (<video>/narracao/duracoes.json): a ação acontece enquanto a voz explica, e a cena seguinte só começa
// quando a fala acabou. O cursor do display se move de verdade até o que vai ser clicado, para quem
// assiste acompanhar; em quiosque, na posição 0,0, as coordenadas da página são as da tela.
const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')

// O playwright-core é da rodada ($RUN/work/node_modules), não da skill: resolve a partir de onde o script roda.
const { chromium } = require(require.resolve('playwright-core', { paths: [process.cwd()] }))

const pausa = (ms) => new Promise(resolve => setTimeout(resolve, ms))

// Chrome headless (macOS: QA_DISPLAY=headless) não tem cursor de sistema nem display para o xdotool. O
// cursor é desenhado na própria página, segue os eventos de mouse que o Playwright dispara, e entra
// no vídeo pelo screencast (gravar-cdp.js). pointer-events: none, então não intercepta nenhum clique.
function cursorNaPagina () {
  if (window.__qaCursor) return
  window.__qaCursor = true
  const pintar = () => {
    if (document.getElementById('__qa-cursor') || !document.documentElement) return
    const c = document.createElement('div')
    c.id = '__qa-cursor'
    c.innerHTML = '<svg width="22" height="30" viewBox="0 0 22 30"><path d="M1 1 L1 24 L7 18.5 L11 28 L15 26.3 L11 17 L19 17 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>'
    c.style.cssText = 'position:fixed;left:0;top:0;width:22px;height:30px;z-index:2147483647;pointer-events:none;' +
      `transform:translate(${window.__qaX || 0}px,${window.__qaY || 0}px)`
    document.documentElement.appendChild(c)
  }
  document.addEventListener('mousemove', e => {
    window.__qaX = e.clientX; window.__qaY = e.clientY
    pintar()
    const c = document.getElementById('__qa-cursor')
    if (c) c.style.transform = `translate(${e.clientX}px,${e.clientY}px)`
  }, true)
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', pintar)
  else pintar()
}

async function iniciar ({ video, display, cdp = 'http://127.0.0.1:9222', folga = 700 }) {
  if (!display || display === process.env.DISPLAY) throw new Error('informe o display da rodada (Xephyr) em `display`; o da sessão do usuário não serve')
  const headless = display === 'headless'
  const xdo = (...args) => execFileSync('xdotool', args, { env: { ...process.env, DISPLAY: display } }).toString()
  const log = path.join(video, 'marcos.jsonl')
  const duracoes = JSON.parse(fs.readFileSync(path.join(video, 'narracao', 'duracoes.json'), 'utf8'))
  const browser = await chromium.connectOverCDP(cdp)
  const context = browser.contexts()[0]
  const page = context.pages()[0] || await context.newPage()
  let pos = null   // headless: onde o cursor desenhado está (não há getmouselocation)
  if (headless) {
    await context.addInitScript(cursorNaPagina)   // volta a cada navegação
    await page.evaluate(cursorNaPagina)
    const { w, h } = await page.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }))
    pos = [Math.round(w / 2), Math.round(h / 2)]
    await page.mouse.move(...pos)
  }
  const marco = (tipo, cena = '') => fs.appendFileSync(log, JSON.stringify({ t: Date.now() / 1000, em: new Date().toISOString(), tipo, cena }) + '\n')

  async function moverPara (x, y, ms = 600) {
    const [cx, cy] = headless ? pos : xdo('getmouselocation', '--shell').match(/X=(\d+)\nY=(\d+)/).slice(1).map(Number)
    const passos = Math.max(8, Math.round(ms / 16))
    for (let i = 1; i <= passos; i++) {
      const k = i / passos
      const e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2   // acelera e freia, como a mão
      if (headless) {
        pos = [Math.round(cx + (x - cx) * e), Math.round(cy + (y - cy) * e)]
        await page.mouse.move(...pos)
      } else {
        xdo('mousemove', String(Math.round(cx + (x - cx) * e)), String(Math.round(cy + (y - cy) * e)))
      }
      await pausa(16)
    }
  }

  // `dx`/`dy` deslocam o ponto final a partir do centro: use para o cursor parar AO LADO de um
  // contador ou selo que a fala cita (ex.: { dx: -28, dy: 22 }), em vez de cobri-lo.
  async function apontar (alvo, { dx = 0, dy = 0 } = {}) {
    const loc = typeof alvo === 'string' ? page.locator(alvo).first() : alvo
    await loc.scrollIntoViewIfNeeded()
    const box = await loc.boundingBox()
    if (!box) throw new Error(`elemento sem posição na tela: ${alvo}`)
    await moverPara(box.x + box.width / 2 + dx, box.y + box.height / 2 + dy)
    return loc
  }

  return {
    page,
    pausa,
    apontar,
    async clicar (alvo) { const loc = await apontar(alvo); await pausa(250); await loc.click() },
    async digitar (alvo, texto, atraso = 75) { const loc = await apontar(alvo); await loc.click(); await loc.pressSequentially(texto, { delay: atraso }) },
    async marcar (alvo, valor = true) { const loc = await apontar(alvo); await pausa(250); await loc.setChecked(valor) },
    async tecla (nome) { await pausa(300); await page.keyboard.press(nome) },
    // `preparo` roda antes da fala começar (abrir modal, escolher registro): a voz entra junto da ação que
    // ela descreve, e o tempo de preparo não aparece como silêncio no meio da fala.
    async cena (id, acoes, preparo) {
      if (!(id in duracoes)) throw new Error(`cena ${id} sem fala em duracoes.json — rode o qa_video.py narrar`)
      if (preparo) await preparo()
      marco('cena', id)
      const t0 = Date.now()
      await acoes()
      const resta = duracoes[id] * 1000 + folga - (Date.now() - t0)
      if (resta > 0) await pausa(resta)
    },
    async fim () { await pausa(800); await browser.close().catch(() => {}) }
  }
}

module.exports = { iniciar, pausa }
