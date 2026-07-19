// ../MyProject/readout-desktop/src/shared/vertical-japanese-ocr.ts
function classifyVerticalJapaneseColumnHints(hints) {
  const parent = hints.map((_, index) => index);
  const find = (index) => {
    while (parent[index] !== index) {
      parent[index] = parent[parent[index]];
      index = parent[index];
    }
    return index;
  };
  const union = (first, second) => {
    const firstRoot = find(first);
    const secondRoot = find(second);
    if (firstRoot !== secondRoot) parent[secondRoot] = firstRoot;
  };
  const range = (hint) => {
    const start = hint.startPositionId;
    const end = hint.endPositionId;
    return Number.isFinite(start) && Number.isFinite(end) && end >= start ? { start, end, length: end - start + 1 } : null;
  };
  for (let first = 0; first < hints.length; first++) {
    const firstRange = range(hints[first]);
    if (!firstRange) continue;
    for (let second = first + 1; second < hints.length; second++) {
      const secondRange = range(hints[second]);
      if (!secondRange) continue;
      const overlap = Math.max(
        0,
        Math.min(firstRange.end, secondRange.end) - Math.max(firstRange.start, secondRange.start) + 1
      );
      const smaller = Math.min(firstRange.length, secondRange.length);
      if (overlap / Math.max(1, smaller) >= 0.9) union(first, second);
    }
  }
  const components = /* @__PURE__ */ new Map();
  for (let index = 0; index < hints.length; index++) {
    const root = find(index);
    const component = components.get(root) || [];
    component.push(index);
    components.set(root, component);
  }
  const result = hints.map((hint) => ({
    ...hint,
    required: hint.required !== false
  }));
  const visualArea = (hint) => Math.max(0, hint.rightRatio - hint.leftRatio) * Math.max(0, (hint.bottomRatio ?? 1) - (hint.topRatio ?? 0));
  for (const indices of components.values()) {
    if (indices.length <= 1) continue;
    const candidates = indices.filter((index) => hints[index].required !== false);
    if (candidates.length === 0) continue;
    const baseIndex = candidates.reduce(
      (best, index) => visualArea(hints[index]) > visualArea(hints[best]) ? index : best
    );
    const ranges = indices.map((index) => range(hints[index])).filter((item) => item !== null);
    const logicalStart = Math.min(...ranges.map((item) => item.start));
    const logicalEnd = Math.max(...ranges.map((item) => item.end));
    const logicalCharacters = Math.max(
      logicalEnd - logicalStart + 1,
      ...indices.map((index) => Math.max(0, hints[index].expectedCharacters ?? 0))
    );
    for (const index of indices) {
      result[index].required = index === baseIndex;
    }
    result[baseIndex].startPositionId = logicalStart;
    result[baseIndex].endPositionId = logicalEnd;
    result[baseIndex].expectedCharacters = logicalCharacters;
  }
  return result;
}
function median(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
function normalizeVerticalJapaneseToken(text) {
  return text.normalize("NFKC").replace(/\s+/g, "").trim();
}
function detectInkBands(pixels, width, height) {
  const inkCounts = Array.from({ length: width }, () => 0);
  for (let x = 0; x < width; x++) {
    for (let y = 0; y < height; y++) {
      const offset = (y * width + x) * 4;
      if (pixels[offset + 3] <= 127) continue;
      const luminance = pixels[offset] * 0.299 + pixels[offset + 1] * 0.587 + pixels[offset + 2] * 0.114;
      if (luminance < 180) inkCounts[x]++;
    }
  }
  const minimumInk = Math.max(3, height * 8e-3);
  const maximumGap = Math.max(2, Math.round(width * 4e-3));
  const bands = [];
  let start = -1;
  let lastInk = -1;
  for (let x = 0; x < width; x++) {
    if (inkCounts[x] >= minimumInk) {
      if (start < 0) start = x;
      lastInk = x;
      continue;
    }
    if (start >= 0 && x - lastInk > maximumGap) {
      if (lastInk + 1 - start >= 3) bands.push({ left: start, right: lastInk + 1 });
      start = -1;
      lastInk = -1;
    }
  }
  if (start >= 0 && lastInk + 1 - start >= 3) {
    bands.push({ left: start, right: lastInk + 1 });
  }
  return { bands, inkCounts };
}
function detectColumnInkEnvelope(pixels, width, height, centerX, pitch, bandWidth = pitch * 0.55) {
  const halfWidth = Math.max(3, Math.round(Math.min(pitch * 0.28, bandWidth * 0.75)));
  const left = Math.max(0, Math.floor(centerX - halfWidth));
  const right = Math.min(width, Math.ceil(centerX + halfWidth));
  const minimumRowInk = Math.max(1, Math.floor((right - left) * 0.04));
  let top = -1;
  let bottom = -1;
  let inkPixels = 0;
  const activeRows = [];
  for (let y = 0; y < height; y++) {
    let rowInk = 0;
    for (let x = left; x < right; x++) {
      const offset = (y * width + x) * 4;
      if (pixels[offset + 3] <= 127) continue;
      const luminance = pixels[offset] * 0.299 + pixels[offset + 1] * 0.587 + pixels[offset + 2] * 0.114;
      if (luminance < 180) rowInk++;
    }
    inkPixels += rowInk;
    if (rowInk >= minimumRowInk) {
      if (top < 0) top = y;
      bottom = y + 1;
      activeRows.push(y);
    }
  }
  if (top < 0 || bottom <= top) return null;
  const maximumWithinRunGap = Math.max(2, Math.round(pitch * 0.08));
  let rowRuns = 0;
  let previousRow = Number.NEGATIVE_INFINITY;
  for (const row of activeRows) {
    if (row - previousRow > maximumWithinRunGap) rowRuns++;
    previousRow = row;
  }
  const envelopeHeight = Math.max(1, bottom - top);
  const envelopeWidth = Math.max(1, right - left);
  return {
    top,
    bottom,
    rowRuns,
    rowCoverage: activeRows.length / envelopeHeight,
    density: inkPixels / (envelopeWidth * envelopeHeight)
  };
}
function estimateColumnPitch(bands, imageWidth) {
  const centers = bands.map((band) => (band.left + band.right) / 2);
  const plausibleGaps = centers.slice(1).map((center, index) => center - centers[index]).filter((gap) => gap >= imageWidth * 0.025 && gap <= imageWidth * 0.075);
  return median(plausibleGaps) || imageWidth * 0.045;
}
function snapVerticalJapaneseColumnCenters(expectedCenters, bands, pitch, required = expectedCenters.map(() => true)) {
  const result = [...expectedCenters];
  if (bands.length === 0 || !(pitch > 0)) return result;
  const bandCenters = bands.map((band) => (band.left + band.right) / 2);
  const used = /* @__PURE__ */ new Set();
  const requiredIndices = expectedCenters.map((center, index) => ({ center, index })).filter(({ index }) => required[index] !== false).sort((first, second) => second.center - first.center);
  let previousPhysicalCenter = Number.POSITIVE_INFINITY;
  for (const { center, index } of requiredIndices) {
    let bestBand = -1;
    let bestDistance = Number.POSITIVE_INFINITY;
    for (let bandIndex = 0; bandIndex < bandCenters.length; bandIndex++) {
      if (used.has(bandIndex)) continue;
      const bandCenter = bandCenters[bandIndex];
      if (bandCenter >= previousPhysicalCenter - pitch * 0.2) continue;
      const distance = Math.abs(bandCenter - center);
      if (distance <= pitch * 0.68 && distance < bestDistance) {
        bestBand = bandIndex;
        bestDistance = distance;
      }
    }
    if (bestBand >= 0) {
      result[index] = bandCenters[bestBand];
      used.add(bestBand);
      previousPhysicalCenter = bandCenters[bestBand];
    } else {
      previousPhysicalCenter = center;
    }
  }
  return result;
}
function alignVerticalJapaneseColumnCenters(expectedCenters, inkCounts, pitch) {
  if (expectedCenters.length === 0 || inkCounts.length === 0 || !(pitch > 0)) {
    return { centers: [...expectedCenters], scale: 1, shift: 0 };
  }
  const radius = Math.max(2, Math.round(pitch * 0.32));
  const windowInk = (center) => {
    const left = Math.max(0, Math.floor(center - radius));
    const right = Math.min(inkCounts.length - 1, Math.ceil(center + radius));
    let score = 0;
    for (let x = left; x <= right; x++) {
      const weight = Math.max(0, 1 - Math.abs(x - center) / (radius + 1));
      score += inkCounts[x] * weight;
    }
    return score;
  };
  const pageCenter = (inkCounts.length - 1) / 2;
  const scaleSteps = [0.98, 0.99, 1, 1.01, 1.02];
  const maximumShift = Math.max(2, Math.round(pitch * 1.25));
  let bestScale = 1;
  let bestShift = 0;
  let bestScore = Number.NEGATIVE_INFINITY;
  for (const scale of scaleSteps) {
    for (let shift = -maximumShift; shift <= maximumShift; shift++) {
      let score = 0;
      for (const expectedCenter of expectedCenters) {
        const center = pageCenter + (expectedCenter - pageCenter) * scale + shift;
        score += Math.sqrt(windowInk(center));
      }
      score -= Math.abs(scale - 1) * expectedCenters.length * 2;
      score -= Math.abs(shift) / Math.max(1, pitch) * 0.02;
      if (score > bestScore) {
        bestScore = score;
        bestScale = scale;
        bestShift = shift;
      }
    }
  }
  return {
    centers: expectedCenters.map(
      (center) => pageCenter + (center - pageCenter) * bestScale + bestShift
    ),
    scale: bestScale,
    shift: bestShift
  };
}
function rotateCounterClockwise(source) {
  const rotated = document.createElement("canvas");
  rotated.width = source.height;
  rotated.height = source.width;
  const context = rotated.getContext("2d");
  context.translate(rotated.width / 2, rotated.height / 2);
  context.rotate(-Math.PI / 2);
  context.drawImage(source, -source.width / 2, -source.height / 2);
  return rotated;
}
function mapCounterClockwiseRectToSource(rect, cropLeft, cropWidth, cropTop = 0) {
  return {
    left: cropLeft + cropWidth - rect.bottom,
    top: cropTop + rect.left,
    right: cropLeft + cropWidth - rect.top,
    bottom: cropTop + rect.right
  };
}
function isReadableJapaneseColumn(text) {
  const japanese = text.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/gu)?.length ?? 0;
  const readable = text.match(/[\p{L}\p{N}]/gu)?.length ?? 0;
  return japanese >= 2 && japanese / Math.max(1, readable) >= 0.45;
}
function containsJapaneseText(text) {
  return countJapaneseCharacters(text) >= 2;
}
function countJapaneseCharacters(text) {
  return text.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/gu)?.length ?? 0;
}
function evaluateVerticalJapaneseColumnQuality(text, words, expectedCharacters, expectedTop, expectedBottom, pitch) {
  const normalizedLength = Array.from(normalizeVerticalJapaneseToken(text)).length;
  const characterCoverage = expectedCharacters > 0 ? normalizedLength / expectedCharacters : normalizedLength > 0 ? 1 : 0;
  const firstTop = words.length > 0 ? Math.min(...words.map((word) => word.top)) : Infinity;
  const lastBottom = words.length > 0 ? Math.max(...words.map((word) => word.bottom)) : -Infinity;
  const expectedHeight = Math.max(1, expectedBottom - expectedTop);
  const edgeTolerance = Math.max(4, pitch * 0.9, expectedHeight * 0.06);
  const startCovered = firstTop <= expectedTop + edgeTolerance;
  const endCovered = lastBottom >= expectedBottom - edgeTolerance;
  const japanese = countJapaneseCharacters(text);
  const purity = japanese / Math.max(1, normalizedLength);
  const lengthCloseness = Math.max(0, 1 - Math.abs(1 - characterCoverage));
  const edgeScore = (startCovered ? 0.5 : 0) + (endCovered ? 0.5 : 0);
  const score = lengthCloseness * 0.45 + edgeScore * 0.4 + purity * 0.15;
  const minimumJapaneseCharacters = expectedCharacters > 0 && expectedCharacters <= 4 ? 1 : 2;
  const characterCountComplete = expectedCharacters <= 0 ? normalizedLength > 0 : expectedCharacters <= 4 ? Math.abs(normalizedLength - expectedCharacters) <= 1 : characterCoverage >= 0.65 && characterCoverage <= 1.45;
  return {
    complete: japanese >= minimumJapaneseCharacters && characterCountComplete && startCovered && endCovered,
    score,
    characterCoverage,
    startCovered,
    endCovered
  };
}
function resolveVerticalJapaneseExpectedCharacters(_tokenExpectedCharacters, expectedTop, expectedBottom, pitch) {
  if (!(pitch > 0) || !(expectedBottom > expectedTop)) return 0;
  return Math.max(
    1,
    Math.round(Math.max(1, expectedBottom - expectedTop) / (pitch * 0.62))
  );
}
function shouldStartVerticalJapaneseParagraph(previous, current, pitch) {
  const previousEnd = previous.endPositionId;
  const currentStart = current.startPositionId;
  if (Number.isFinite(previousEnd) && Number.isFinite(currentStart)) {
    return currentStart > previousEnd + 1;
  }
  return Math.abs(previous.centerX - current.centerX) > pitch * 1.8;
}
function groupColumnsIntoParagraphs(columns, pitch) {
  const narrationColumns = columns.filter(
    (column) => column.text.length > 0 && column.words.length > 0
  );
  if (narrationColumns.length === 0) return [];
  const groups = [[narrationColumns[0]]];
  for (let index = 1; index < narrationColumns.length; index++) {
    const previous = narrationColumns[index - 1];
    const current = narrationColumns[index];
    if (shouldStartVerticalJapaneseParagraph(previous, current, pitch)) groups.push([current]);
    else groups[groups.length - 1].push(current);
  }
  return groups.map((group) => ({
    text: group.map((column) => column.text).join(""),
    words: group.flatMap((column) => column.words)
  }));
}
function recognizeVerticalJapanesePage(engine, bitmap, columnHints) {
  const source = document.createElement("canvas");
  source.width = bitmap.width;
  source.height = bitmap.height;
  const sourceContext = source.getContext("2d", { willReadFrequently: true });
  sourceContext.drawImage(bitmap, 0, 0);
  const sourceImage = sourceContext.getImageData(0, 0, source.width, source.height);
  const detected = detectInkBands(sourceImage.data, source.width, source.height);
  const hintedSlots = columnHints?.map((hint, slotIndex) => ({
    slotIndex,
    left: Math.max(0, Math.floor(hint.leftRatio * source.width)),
    right: Math.min(source.width, Math.ceil(hint.rightRatio * source.width)),
    top: Math.max(0, Math.floor((hint.topRatio ?? 0) * source.height)),
    bottom: Math.min(source.height, Math.ceil((hint.bottomRatio ?? 1) * source.height)),
    expectedCharacters: Math.max(0, Math.round(hint.expectedCharacters ?? 0)),
    startPositionId: hint.startPositionId,
    endPositionId: hint.endPositionId,
    required: hint.required !== false
  })).filter((slot) => slot.right - slot.left >= 2 && slot.bottom - slot.top >= 2);
  const slots = hintedSlots?.length ? hintedSlots : [...detected.bands].reverse().map((band, slotIndex) => ({
    slotIndex,
    ...band,
    top: 0,
    bottom: source.height,
    expectedCharacters: 0,
    startPositionId: void 0,
    endPositionId: void 0,
    required: true
  }));
  const geometryBands = slots.map(({ left, right }) => ({ left, right })).sort((first, second) => first.left - second.left);
  const inkCounts = detected.inkCounts;
  const pitch = estimateColumnPitch(
    detected.bands.length >= 3 ? detected.bands : geometryBands,
    source.width
  );
  const expectedCenters = slots.map((slot) => (slot.left + slot.right) / 2);
  const requiredCenterIndices = slots.map((slot, index) => ({ slot, index })).filter(({ slot }) => slot.required).map(({ index }) => index);
  const requiredExpectedCenters = requiredCenterIndices.map((index) => expectedCenters[index]);
  const requiredAlignment = hintedSlots?.length ? alignVerticalJapaneseColumnCenters(requiredExpectedCenters, inkCounts, pitch) : { centers: requiredExpectedCenters, scale: 1, shift: 0 };
  const pageCenter = (source.width - 1) / 2;
  const globallyAlignedCenters = hintedSlots?.length ? expectedCenters.map(
    (center) => pageCenter + (center - pageCenter) * requiredAlignment.scale + requiredAlignment.shift
  ) : expectedCenters;
  const physicalCenters = hintedSlots?.length ? snapVerticalJapaneseColumnCenters(
    globallyAlignedCenters,
    detected.bands,
    pitch,
    slots.map((slot) => slot.required)
  ) : globallyAlignedCenters;
  const alignment = hintedSlots?.length ? {
    centers: physicalCenters,
    scale: requiredAlignment.scale,
    shift: requiredAlignment.shift
  } : { centers: expectedCenters, scale: 1, shift: 0 };
  const columns = [];
  const centerShifts = [];
  let recoveredColumns = 0;
  let requiredColumns = 0;
  let unresolvedColumns = 0;
  const incompleteColumns = [];
  const recognizeAtCenter = (centerX, bandWidth, focus, pageSegMode = 7) => {
    const cropWidth = Math.max(
      12,
      Math.round(
        focus ? Math.max(pitch, bandWidth + pitch * 0.1) : Math.max(pitch * 1.45, bandWidth + pitch * 0.35)
      )
    );
    const cropLeft = Math.max(
      0,
      Math.min(source.width - cropWidth, Math.round(centerX - cropWidth / 2))
    );
    const focusPadding = Math.max(8, Math.round(pitch * 0.8));
    const cropTop = focus ? Math.max(0, Math.floor(focus.top - focusPadding)) : 0;
    const cropBottom = focus ? Math.min(source.height, Math.ceil(focus.bottom + focusPadding)) : source.height;
    const cropHeight = Math.max(1, cropBottom - cropTop);
    const crop = document.createElement("canvas");
    crop.width = Math.min(cropWidth, source.width);
    crop.height = cropHeight;
    crop.getContext("2d").drawImage(
      source,
      cropLeft,
      cropTop,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    const rotated = rotateCounterClockwise(crop);
    let textBoxes = [];
    try {
      engine.setVariable("tessedit_pageseg_mode", String(pageSegMode));
      engine.loadImage(
        rotated.getContext("2d").getImageData(0, 0, rotated.width, rotated.height)
      );
      textBoxes = engine.getTextBoxes("word");
    } catch (error) {
      console.warn("[jpn-vert-ocr] column recognition failed:", error);
    } finally {
      try {
        engine.clearImage();
      } catch {
      }
    }
    const words = textBoxes.map((item) => {
      const text2 = normalizeVerticalJapaneseToken(item.text);
      const rect = mapCounterClockwiseRectToSource(item.rect, cropLeft, crop.width, cropTop);
      return {
        text: text2,
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
        confidence: item.confidence
      };
    }).filter(
      (word) => word.text.length > 0 && word.right > word.left && word.bottom > word.top && word.left >= 0 && word.right <= source.width && word.top >= 0 && word.bottom <= source.height && // The crop is intentionally wider than a glyph column so PSM 7 sees
      // sufficient whitespace. Geometry still assigns output exclusively
      // to this fixed slot.
      Math.abs((word.left + word.right) / 2 - centerX) <= pitch * 0.52
    ).sort((first, second) => first.top - second.top);
    const text = words.map((word) => word.text).join("");
    return { centerX, text, words };
  };
  const recognizeNativeVerticalAtCenter = (centerX, bandWidth, focus, pageSegMode = 5) => {
    const cropWidth = Math.max(
      12,
      Math.round(Math.max(pitch * 1.15, bandWidth + pitch * 0.2))
    );
    const cropLeft = Math.max(
      0,
      Math.min(source.width - cropWidth, Math.round(centerX - cropWidth / 2))
    );
    const focusPadding = Math.max(8, Math.round(pitch * 0.8));
    const cropTop = Math.max(0, Math.floor(focus.top - focusPadding));
    const cropBottom = Math.min(source.height, Math.ceil(focus.bottom + focusPadding));
    const crop = document.createElement("canvas");
    crop.width = Math.min(cropWidth, source.width);
    crop.height = Math.max(1, cropBottom - cropTop);
    crop.getContext("2d").drawImage(
      source,
      cropLeft,
      cropTop,
      crop.width,
      crop.height,
      0,
      0,
      crop.width,
      crop.height
    );
    let textBoxes = [];
    try {
      engine.setVariable("tessedit_pageseg_mode", String(pageSegMode));
      engine.loadImage(crop.getContext("2d").getImageData(0, 0, crop.width, crop.height));
      textBoxes = engine.getTextBoxes("word");
    } catch (error) {
      console.warn("[jpn-vert-ocr] native vertical column recognition failed:", error);
    } finally {
      try {
        engine.clearImage();
      } catch {
      }
    }
    const words = textBoxes.map((item) => ({
      text: normalizeVerticalJapaneseToken(item.text),
      left: cropLeft + item.rect.left,
      top: cropTop + item.rect.top,
      right: cropLeft + item.rect.right,
      bottom: cropTop + item.rect.bottom,
      confidence: item.confidence
    })).filter(
      (word) => word.text.length > 0 && word.right > word.left && word.bottom > word.top && Math.abs((word.left + word.right) / 2 - centerX) <= pitch * 0.52
    ).sort((first, second) => first.top - second.top);
    return {
      centerX,
      text: words.map((word) => word.text).join(""),
      words
    };
  };
  let wholePageWordsCache = null;
  const getWholePageWords = () => {
    if (wholePageWordsCache) return wholePageWordsCache;
    let textBoxes = [];
    try {
      engine.setVariable("tessedit_pageseg_mode", "5");
      engine.loadImage(sourceImage);
      textBoxes = engine.getTextBoxes("word");
    } catch (error) {
      console.warn("[jpn-vert-ocr] whole-page recovery failed:", error);
    } finally {
      try {
        engine.clearImage();
      } catch {
      }
    }
    wholePageWordsCache = textBoxes.map((item) => ({
      text: normalizeVerticalJapaneseToken(item.text),
      left: item.rect.left,
      top: item.rect.top,
      right: item.rect.right,
      bottom: item.rect.bottom,
      confidence: item.confidence
    })).filter(
      (word) => word.text.length > 0 && word.right > word.left && word.bottom > word.top && word.left >= 0 && word.right <= source.width && word.top >= 0 && word.bottom <= source.height
    );
    return wholePageWordsCache;
  };
  const mergeRecognizedColumns = (...parts) => {
    const candidates = parts.flatMap((part) => part.words).sort((first, second) => first.top - second.top || first.left - second.left);
    const words = [];
    for (const candidate of candidates) {
      const candidateCenterY = (candidate.top + candidate.bottom) / 2;
      const duplicateIndex = words.findIndex((word) => {
        const wordCenterY = (word.top + word.bottom) / 2;
        const verticalTolerance = Math.max(
          3,
          Math.min(candidate.bottom - candidate.top, word.bottom - word.top) * 0.35
        );
        return Math.abs(candidateCenterY - wordCenterY) <= verticalTolerance && Math.abs((candidate.left + candidate.right - word.left - word.right) / 2) <= pitch * 0.3;
      });
      if (duplicateIndex < 0) words.push(candidate);
      else if (candidate.confidence > words[duplicateIndex].confidence) {
        words[duplicateIndex] = candidate;
      }
    }
    words.sort((first, second) => first.top - second.top);
    return {
      centerX: parts.find((part) => part.words.length > 0)?.centerX ?? parts[0]?.centerX ?? 0,
      text: words.map((word) => word.text).join(""),
      words
    };
  };
  for (let slotIndex = 0; slotIndex < slots.length; slotIndex++) {
    const slot = slots[slotIndex];
    const expectedCenter = expectedCenters[slotIndex];
    const layoutCenter = alignment.centers[slotIndex];
    const fallbackCenter = inkCounts.slice(slot.left, slot.right).reduce(
      (best, count, offset) => count > best.count ? { x: slot.left + offset, count } : best,
      { x: expectedCenter, count: -1 }
    ).x;
    const initialCenter = hintedSlots?.length ? layoutCenter : fallbackCenter;
    const bandWidth = slot.right - slot.left;
    const expectedCharacters = slot.expectedCharacters;
    if (hintedSlots?.length && !slot.required) {
      columns.push({
        slotIndex,
        centerX: layoutCenter,
        text: "",
        words: [],
        startPositionId: slot.startPositionId,
        endPositionId: slot.endPositionId
      });
      centerShifts.push(layoutCenter - expectedCenter);
      continue;
    }
    const nearestPhysicalBand = detected.bands.reduce((best, band) => {
      const bandCenter = (band.left + band.right) / 2;
      const bestDistance = best ? Math.abs((best.left + best.right) / 2 - layoutCenter) : Number.POSITIVE_INFINITY;
      return Math.abs(bandCenter - layoutCenter) < bestDistance ? band : best;
    }, null);
    const physicalBandWidth = nearestPhysicalBand ? nearestPhysicalBand.right - nearestPhysicalBand.left : bandWidth;
    const inkEnvelope = detectColumnInkEnvelope(
      sourceImage.data,
      source.width,
      source.height,
      layoutCenter,
      pitch,
      physicalBandWidth
    );
    const expectedTop = inkEnvelope?.top ?? slot.top;
    const expectedBottom = inkEnvelope?.bottom ?? slot.bottom;
    const effectiveExpectedCharacters = resolveVerticalJapaneseExpectedCharacters(
      expectedCharacters,
      expectedTop,
      expectedBottom,
      pitch
    );
    let recognized = recognizeAtCenter(initialCenter, bandWidth);
    const assess = (candidate) => evaluateVerticalJapaneseColumnQuality(
      candidate.text,
      candidate.words,
      effectiveExpectedCharacters,
      expectedTop,
      expectedBottom,
      pitch
    );
    const initialQuality = assess(recognized);
    if (hintedSlots?.length && !initialQuality.complete) {
      const focused = recognizeAtCenter(initialCenter, bandWidth, {
        top: expectedTop,
        bottom: expectedBottom
      });
      if (assess(focused).score > assess(recognized).score) recognized = focused;
      for (const offsetRatio of [0.18, -0.18, 0.32, -0.32]) {
        const candidateCenter = Math.max(
          0,
          Math.min(source.width - 1, layoutCenter + pitch * offsetRatio)
        );
        const candidate = recognizeAtCenter(candidateCenter, bandWidth, {
          top: expectedTop,
          bottom: expectedBottom
        });
        if (assess(candidate).score > assess(recognized).score) recognized = candidate;
      }
      if (assess(recognized).score > initialQuality.score) {
        recoveredColumns++;
      }
    }
    const expectedHeight = Math.max(1, expectedBottom - expectedTop);
    if (!assess(recognized).complete && expectedHeight <= pitch * 6) {
      const rawLine = recognizeAtCenter(
        initialCenter,
        physicalBandWidth,
        { top: expectedTop, bottom: expectedBottom },
        13
      );
      if (assess(rawLine).score > assess(recognized).score) {
        recognized = rawLine;
        recoveredColumns++;
      }
      if (!assess(recognized).complete) {
        for (const pageSegMode of [5, 6]) {
          const nativeVertical = recognizeNativeVerticalAtCenter(
            initialCenter,
            physicalBandWidth,
            { top: expectedTop, bottom: expectedBottom },
            pageSegMode
          );
          if (assess(nativeVertical).score > assess(recognized).score) {
            recognized = nativeVertical;
            recoveredColumns++;
          }
          if (assess(recognized).complete) break;
        }
      }
    }
    let edgeQuality = assess(recognized);
    let edgeRecovered = false;
    if (!edgeQuality.startCovered) {
      const firstTop = recognized.words.length ? Math.min(...recognized.words.map((word) => word.top)) : expectedTop + expectedHeight * 0.5;
      const prefix = recognizeAtCenter(recognized.centerX, physicalBandWidth, {
        top: expectedTop,
        bottom: Math.min(
          expectedBottom,
          Math.max(expectedTop + pitch * 4, firstTop + pitch * 0.75)
        )
      });
      const merged = mergeRecognizedColumns(prefix, recognized);
      if (assess(merged).score > edgeQuality.score) {
        recognized = merged;
        edgeQuality = assess(recognized);
        edgeRecovered = true;
      }
    }
    if (!edgeQuality.endCovered) {
      const lastBottom = recognized.words.length ? Math.max(...recognized.words.map((word) => word.bottom)) : expectedBottom - expectedHeight * 0.5;
      const suffix = recognizeAtCenter(recognized.centerX, physicalBandWidth, {
        top: Math.max(
          expectedTop,
          Math.min(expectedBottom - pitch * 4, lastBottom - pitch * 0.75)
        ),
        bottom: expectedBottom
      });
      const merged = mergeRecognizedColumns(recognized, suffix);
      if (assess(merged).score > edgeQuality.score) {
        recognized = merged;
        edgeRecovered = true;
      }
    }
    if (edgeRecovered) recoveredColumns++;
    if (!assess(recognized).complete) {
      const horizontalTolerance = Math.max(pitch * 0.55, physicalBandWidth * 0.8);
      const verticalTolerance = Math.max(4, pitch * 0.35);
      const pageWords = getWholePageWords().filter((word) => {
        const centerX = (word.left + word.right) / 2;
        return Math.abs(centerX - layoutCenter) <= horizontalTolerance && word.bottom >= expectedTop - verticalTolerance && word.top <= expectedBottom + verticalTolerance;
      }).sort((first, second) => first.top - second.top);
      if (pageWords.length > 0) {
        const pageCandidate = {
          centerX: layoutCenter,
          text: pageWords.map((word) => word.text).join(""),
          words: pageWords
        };
        const mergedCandidate = mergeRecognizedColumns(recognized, pageCandidate);
        const bestCandidate = assess(mergedCandidate).score > assess(pageCandidate).score ? mergedCandidate : pageCandidate;
        if (assess(bestCandidate).score > assess(recognized).score) {
          recognized = bestCandidate;
          recoveredColumns++;
        }
      }
    }
    if (hintedSlots?.length) centerShifts.push(layoutCenter - expectedCenter);
    const { text, words } = recognized;
    const required = hintedSlots?.length && slot.required && expectedBottom > expectedTop;
    if (required) {
      requiredColumns++;
      const quality = assess(recognized);
      if (!quality.complete) {
        unresolvedColumns++;
        const recognizedTopValue = words.length ? Math.min(...words.map((word) => word.top)) : null;
        const recognizedBottomValue = words.length ? Math.max(...words.map((word) => word.bottom)) : null;
        incompleteColumns.push({
          slotIndex,
          tokenLeft: slot.left,
          tokenRight: slot.right,
          alignedCenterX: layoutCenter,
          physicalBandLeft: nearestPhysicalBand?.left ?? null,
          physicalBandRight: nearestPhysicalBand?.right ?? null,
          expectedCharacters,
          effectiveExpectedCharacters,
          recognizedCharacters: Array.from(normalizeVerticalJapaneseToken(text)).length,
          characterCoverage: quality.characterCoverage,
          startCovered: quality.startCovered,
          endCovered: quality.endCovered,
          recognizedTop: recognizedTopValue,
          recognizedBottom: recognizedBottomValue,
          expectedTop,
          expectedBottom,
          inkRowRuns: inkEnvelope?.rowRuns ?? 0,
          inkRowCoverage: inkEnvelope?.rowCoverage ?? 0,
          inkDensity: inkEnvelope?.density ?? 0,
          text: text.substring(0, 64)
        });
        const recognizedTop = recognizedTopValue?.toFixed(0) ?? "?";
        const recognizedBottom = recognizedBottomValue?.toFixed(0) ?? "?";
        console.warn(
          `[jpn-vert-ocr] incomplete slot=${slotIndex} expectedChars=${expectedCharacters}${effectiveExpectedCharacters !== expectedCharacters ? ` effective=${effectiveExpectedCharacters || "pixel"}` : ""} coverage=${quality.characterCoverage.toFixed(2)} edges=${quality.startCovered ? "start\u2713" : "start\u2717"}/${quality.endCovered ? "end\u2713" : "end\u2717"} recognizedY=${recognizedTop}..${recognizedBottom} expectedY=${expectedTop.toFixed(0)}..${expectedBottom.toFixed(0)} x=${layoutCenter.toFixed(0)} band=${nearestPhysicalBand?.left.toFixed(0) ?? "?"}..${nearestPhysicalBand?.right.toFixed(0) ?? "?"} ink=runs${inkEnvelope?.rowRuns ?? 0}/rows${(inkEnvelope?.rowCoverage ?? 0).toFixed(2)}/density${(inkEnvelope?.density ?? 0).toFixed(3)} text="${text.substring(0, 32)}"`
        );
      }
    }
    if (!hintedSlots?.length && !isReadableJapaneseColumn(text)) continue;
    columns.push({
      slotIndex,
      centerX: layoutCenter,
      text,
      words,
      startPositionId: slot.startPositionId,
      endPositionId: slot.endPositionId
    });
  }
  const complete = !hintedSlots?.length || unresolvedColumns === 0;
  const paragraphData = groupColumnsIntoParagraphs(columns, pitch).filter(
    (paragraph) => paragraph.text.length > 0
  );
  const paragraphs = paragraphData.map((paragraph) => paragraph.text);
  const paragraphWords = paragraphData.map((paragraph) => paragraph.words);
  const wordBoxes = paragraphWords.flat();
  const outputParagraphs = complete ? paragraphs : [];
  const outputParagraphWords = complete ? paragraphWords : [];
  const outputWordBoxes = complete ? wordBoxes : [];
  console.log(
    `[jpn-vert-ocr] source=${hintedSlots?.length ? "token" : "ink"}, slots=${slots.length}, columns=${columns.filter((column) => containsJapaneseText(column.text)).length}, required=${requiredColumns}, unresolved=${unresolvedColumns}, complete=${complete}, paragraphs=${outputParagraphs.length}, pitch=${pitch.toFixed(1)}, transform=${alignment.scale.toFixed(3)}x${alignment.shift >= 0 ? "+" : ""}${alignment.shift.toFixed(1)}, words=${outputWordBoxes.length}` + (centerShifts.length ? `, centerShift median=${median(centerShifts).toFixed(1)}, range=[${Math.min(...centerShifts)},${Math.max(...centerShifts)}], recovered=${recoveredColumns}` : "")
  );
  return {
    text: outputParagraphs.join("\n\n"),
    paragraphs: outputParagraphs,
    paragraphWords: outputParagraphWords,
    wordBoxes: outputWordBoxes,
    imageWidth: source.width,
    imageHeight: source.height,
    verticalDiagnostics: {
      source: hintedSlots?.length ? "token" : "ink",
      bands: detected.bands.length,
      columns: columns.filter((column) => containsJapaneseText(column.text)).length,
      requiredColumns,
      unresolvedColumns,
      complete,
      pitch,
      globalScale: alignment.scale,
      globalShift: alignment.shift,
      medianCenterShift: median(centerShifts),
      minimumCenterShift: centerShifts.length ? Math.min(...centerShifts) : 0,
      maximumCenterShift: centerShifts.length ? Math.max(...centerShifts) : 0,
      recoveredColumns,
      incompleteColumns
    }
  };
}
export {
  alignVerticalJapaneseColumnCenters,
  classifyVerticalJapaneseColumnHints,
  evaluateVerticalJapaneseColumnQuality,
  mapCounterClockwiseRectToSource,
  recognizeVerticalJapanesePage,
  resolveVerticalJapaneseExpectedCharacters,
  shouldStartVerticalJapaneseParagraph,
  snapVerticalJapaneseColumnCenters
};
