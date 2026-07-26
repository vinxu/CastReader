import { createOCREngine, supportsFastBuild } from './tesseract-lib.js';
import {
  classifyVerticalJapaneseColumnHints,
  recognizeVerticalJapanesePage,
} from './vertical-japanese-ocr.js';

const supportedModels = new Set(['eng', 'chi_sim', 'jpn', 'jpn_vert', 'spa', 'fra', 'deu', 'por', 'ita', 'hin']);
let engine = null;
let loadedModel = '';
let engineLoading = Promise.resolve();
let executionTail = Promise.resolve();

async function getEngine(requestedModel) {
  const model = supportedModels.has(requestedModel) ? requestedModel : 'eng';
  if (engine && loadedModel === model) return engine;

  engineLoading = engineLoading.catch(() => undefined).then(async () => {
    if (engine && loadedModel === model) return;
    if (engine) {
      engine.destroy();
      engine = null;
      loadedModel = '';
    }

    const wasmFile = supportsFastBuild()
      ? './tesseract-wasm/tesseract-core.wasm'
      : './tesseract-wasm/tesseract-core-fallback.wasm';
    const wasmResponse = await fetch(wasmFile);
    if (!wasmResponse.ok && wasmResponse.status !== 0) {
      throw new Error(`OCR runtime unavailable (${wasmResponse.status})`);
    }
    const nextEngine = await createOCREngine({ wasmBinary: await wasmResponse.arrayBuffer() });

    const modelResponse = await fetch(`./tesseract-wasm/${model}.traineddata`);
    if (!modelResponse.ok && modelResponse.status !== 0) {
      throw new Error(`OCR model ${model} unavailable (${modelResponse.status})`);
    }
    nextEngine.loadModel(await modelResponse.arrayBuffer());
    nextEngine.setVariable('tessedit_pageseg_mode', model === 'jpn_vert' ? '5' : '6');
    engine = nextEngine;
    loadedModel = model;
  });
  await engineLoading;
  return engine;
}

async function recognize(dataURL, model, verticalColumnHints) {
  const activeEngine = await getEngine(model);
  const response = await fetch(dataURL);
  const blob = await response.blob();
  const bitmap = await createImageBitmap(blob);
  try {
    if (loadedModel === 'jpn_vert') {
      const hints = classifyVerticalJapaneseColumnHints(verticalColumnHints || []);
      const vertical = recognizeVerticalJapanesePage(activeEngine, bitmap, hints);
      return { success: true, model: loadedModel, ...vertical };
    }
    activeEngine.loadImage(bitmap);
    const text = activeEngine.getText();
    const textItems = activeEngine.getTextBoxes('word');
    // Keep Tesseract's own line segmentation. Reconstructing every line from
    // word-center proximity loses list/headline boundaries in Devanagari and
    // other caseless scripts even when the OCR engine found them correctly.
    const lineItems = activeEngine.getTextBoxes('line');
    return {
      success: true,
      model: loadedModel,
      text,
      imageWidth: bitmap.width,
      imageHeight: bitmap.height,
      wordBoxes: textItems.map((item) => ({
        text: item.text,
        left: item.rect.left,
        top: item.rect.top,
        right: item.rect.right,
        bottom: item.rect.bottom,
        confidence: item.confidence,
      })),
      lineBoxes: lineItems.map((item) => ({
        text: item.text,
        left: item.rect.left,
        top: item.rect.top,
        right: item.rect.right,
        bottom: item.rect.bottom,
        confidence: item.confidence,
      })),
    };
  } finally {
    activeEngine.clearImage();
    bitmap.close();
  }
}

window.castReaderKindleOCR = (dataURL, model, verticalColumnHints) => {
  const run = executionTail.catch(() => undefined)
    .then(() => recognize(dataURL, model, verticalColumnHints));
  executionTail = run.then(() => undefined, () => undefined);
  return run;
};
window.castReaderKindleOCRReady = true;
