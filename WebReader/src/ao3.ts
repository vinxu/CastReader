// AO3 serves the chapter before its delayed terms dialog hides #outer. Treat
// the dialog's presence as a gate, including its initial display:none phase.
// Nothing here accepts a notice, changes cookies, or reveals hidden content.
type Paragraph = { text: string; element: HTMLElement }
type PageState = 'ready' | 'notice' | 'unavailable'

export function isAO3Page(): boolean {
  return /^(?:www\.)?archiveofourown\.(?:org|com|net)$/.test(location.hostname)
    || location.hostname === 'ao3.org'
}

function visible(element: HTMLElement): boolean {
  for (let current: HTMLElement | null = element; current; current = current.parentElement) {
    const style = getComputedStyle(current)
    if (current.hidden || current.getAttribute('aria-hidden') === 'true'
      || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false
  }
  return true
}

function text(element: HTMLElement): string {
  return (element.textContent || '').replace(/\s+/g, ' ').trim()
}

function fingerprint(value: string): string {
  let hash = 2166136261
  for (let i = 0; i < value.length; i++) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619)
  return (hash >>> 0).toString(16)
}

export function makeAO3Reader() {
  const newDocumentID = () => `${Date.now()}-${Math.random().toString(36).slice(2)}`
  let documentID = newDocumentID()
  let state: PageState = 'unavailable'
  let signature = ''
  let paragraphs: Paragraph[] = []
  let lastEmission = ''
  let lastElements: HTMLElement[] = []

  function inspect(): void {
    paragraphs = []
    signature = ''
    if (document.querySelector('#tos_prompt')) { state = 'notice'; return }
    const bodies = Array.from(document.querySelectorAll<HTMLElement>(
      '#chapters .userstuff[role="article"], #chapters .chapter > .userstuff'
    )).filter(visible)
    if (!bodies.length) { state = 'unavailable'; return }

    // Walk blocks in source order. Do not deduplicate repeated lines of fiction
    // or include prefaces, summaries, author notes, chapter controls, or comments.
    function collect(element: HTMLElement): void {
      if (!visible(element) || element.matches('script,style,noscript,nav,form,button,.landmark')) return
      const blockChildren = Array.from(element.children).filter((child): child is HTMLElement =>
        child instanceof HTMLElement && child.matches('p,div,section,blockquote,ul,ol,li,h1,h2,h3,h4,h5,h6,pre,table,tbody,tr,td,[data-cr-ao3-inline]'))
      if (blockChildren.length) {
        // AO3 normally uses <p>, but preserve unwrapped text around nested blocks
        // by giving each inline run a real DOM element for highlight coordinates.
        let inline: Node[] = []
        const flush = () => {
          if (inline.some(node => (node.textContent || '').trim())) {
            const span = document.createElement('span')
            span.setAttribute('data-cr-ao3-inline', '')
            element.insertBefore(span, inline[0])
            inline.forEach(node => span.appendChild(node))
            if (text(span)) paragraphs.push({ text: text(span), element: span })
          }
          inline = []
        }
        for (const node of Array.from(element.childNodes)) {
          if (node instanceof HTMLElement && blockChildren.includes(node)) { flush(); collect(node) }
          else if (!(node instanceof HTMLElement && node.matches('script,style,noscript,.landmark'))) inline.push(node)
        }
        flush()
      } else if (text(element)) paragraphs.push({ text: text(element), element })
    }
    bodies.forEach(collect)
    state = paragraphs.length ? 'ready' : 'unavailable'
    signature = fingerprint(paragraphs.map(p => p.text).join('\n'))
  }

  return {
    extract(): Paragraph[] {
      inspect()
      ;(window as unknown as { __crExtractMethod: string }).__crExtractMethod = 'ao3'
      return paragraphs
    },
    pageMeta(): Record<string, unknown> {
      return { source: 'ao3', documentID, url: location.href, state, signature }
    },
    install(extract: (reason?: string) => void): void {
      let timer: ReturnType<typeof setTimeout> | undefined
      let extracting = false
      const check = () => {
        if (extracting) return
        inspect()
        const key = `${location.pathname}${location.search}|${state}|${signature}`
        if (key === lastEmission && lastElements.every(el => el.isConnected)) return
        extracting = true
        lastEmission = key
        extract('ao3-page-state')
        lastElements = paragraphs.map(p => p.element)
        extracting = false
      }
      const schedule = () => { clearTimeout(timer); timer = setTimeout(check, 100) }
      const observer = new MutationObserver(changes => {
        const relevant = changes.some(change => {
          const element = change.target instanceof Element ? change.target : change.target.parentElement
          if (element?.closest('.cr-hl-ov, svg[data-cr-marks]')) return false
          if (change.type === 'childList') {
            const nodes = [...Array.from(change.addedNodes), ...Array.from(change.removedNodes)]
            if (nodes.length && nodes.every(node => node instanceof Element
              && node.matches('.cr-hl-ov, svg[data-cr-marks], [data-cr-ao3-inline]'))) return false
          }
          return true
        })
        if (relevant) schedule()
      })
      const observe = () => observer.observe(document.documentElement, { subtree: true, childList: true, characterData: true,
        attributes: true, attributeFilter: ['style', 'class', 'hidden', 'aria-hidden'] })
      observe()
      window.addEventListener('pageshow', event => {
        if (event.persisted) {
          // Native retires the previous presentation on navigation. A cached
          // document needs a fresh identity so old queued messages stay stale.
          documentID = newDocumentID()
          lastEmission = ''
        }
        observe()
        schedule()
      })
      window.addEventListener('popstate', schedule)
      window.addEventListener('pagehide', () => { clearTimeout(timer); observer.disconnect() })
      // Site scripts have populated the pending dialog by this point. Keeping
      // its hidden phase gated eliminates the original 350 ms / 1500 ms race.
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', schedule, { once: true })
      else schedule()
    },
  }
}
