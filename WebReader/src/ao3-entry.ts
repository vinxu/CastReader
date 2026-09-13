import { initBridge } from './cr-bridge'
import { isAO3Page, makeAO3Reader } from './ao3'

if (isAO3Page()) {
  const ao3 = makeAO3Reader()
  initBridge({ extract: ao3.extract, pageMeta: ao3.pageMeta, autoExtract: false,
    onInstalled: ({ extract }) => ao3.install(extract) })
}
