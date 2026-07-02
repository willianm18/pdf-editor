/**
 * Client-side document image enhancement built on OpenCV.js (`window.cv`).
 *
 * Every function here is pure with respect to React: it takes and returns
 * `ImageData`, never touching component state. That keeps the signatures ready
 * to move into a Web Worker later without changing callers. All OpenCV `Mat`
 * objects created here are released in `finally` blocks — OpenCV.js does not
 * garbage-collect WASM heap allocations.
 */

/** Selectable enhancement styles offered on the preview screen. */
export type EnhanceFilter =
  | "magicColor"
  | "colorDocument"
  | "clarear"
  | "grayscale"
  | "blackAndWhite"
  | "original";

/** Optional per-filter fine controls the UI can layer on top of any filter. */
export interface EnhanceAdjustments {
  /** Additive brightness in pixel units, roughly [-100, 100]. 0 = no change. */
  brightness?: number;
  /** Multiplicative contrast around black, roughly [0.5, 2]. 1 = no change. */
  contrast?: number;
  /** HSV saturation multiplier for the colour filters. 1 = no change. */
  saturation?: number;
  /**
   * Adaptive-threshold constant `C` for the black & white filter. Higher =
   * cleaner/whiter background; lower = more ink retained. Default ~12.
   */
  bwStrength?: number;
}

// OpenCV.js colour-conversion and morphology constants (plain runtime numbers).
const COLOR_RGBA2RGB = 1;
const COLOR_RGB2RGBA = 0;
const COLOR_RGBA2GRAY = 11;
const COLOR_GRAY2RGBA = 9;
const COLOR_RGB2HSV = 41;
const COLOR_HSV2RGB = 55;
const MORPH_ELLIPSE = 2;
const MORPH_CLOSE = 3;
const ADAPTIVE_THRESH_GAUSSIAN_C = 1;
const THRESH_BINARY = 0;
const COLOR_RGB2LAB = 45;
const COLOR_LAB2RGB = 57;

interface CvMat {
  delete(): void;
  rows: number;
  cols: number;
  data: Uint8Array;
  clone(): CvMat;
}

interface CvClahe {
  apply(src: CvMat, dst: CvMat): void;
  delete(): void;
}

interface CvMatVector {
  get(index: number): CvMat;
  set(index: number, mat: CvMat): void;
  delete(): void;
}

interface CvSize {
  readonly width: number;
  readonly height: number;
}

/** The exact OpenCV.js surface this module relies on. */
interface CvModule {
  Mat: { new (): CvMat };
  MatVector: { new (): CvMatVector };
  Size: { new (width: number, height: number): CvSize };
  matFromImageData(imageData: ImageData): CvMat;
  cvtColor(src: CvMat, dst: CvMat, code: number): void;
  split(src: CvMat, dst: CvMatVector): void;
  merge(src: CvMatVector, dst: CvMat): void;
  convertScaleAbs(src: CvMat, dst: CvMat, alpha: number, beta: number): void;
  medianBlur(src: CvMat, dst: CvMat, ksize: number): void;
  GaussianBlur(src: CvMat, dst: CvMat, ksize: CvSize, sigmaX: number): void;
  addWeighted(
    src1: CvMat,
    alpha: number,
    src2: CvMat,
    beta: number,
    gamma: number,
    dst: CvMat,
  ): void;
  getStructuringElement(shape: number, ksize: CvSize): CvMat;
  morphologyEx(src: CvMat, dst: CvMat, op: number, kernel: CvMat): void;
  divide(src1: CvMat, src2: CvMat, dst: CvMat, scale: number): void;
  adaptiveThreshold(
    src: CvMat,
    dst: CvMat,
    maxValue: number,
    adaptiveMethod: number,
    thresholdType: number,
    blockSize: number,
    c: number,
  ): void;
  CLAHE: new (clipLimit: number, tileGridSize: CvSize) => CvClahe;
}

function getCv(): CvModule {
  const cv = window.cv as unknown as CvModule | undefined;
  if (!cv) throw new Error("OpenCV.js (window.cv) is not loaded");
  return cv;
}

function hasAdjustments(adjustments?: EnhanceAdjustments): boolean {
  if (!adjustments) return false;
  return (
    (adjustments.contrast ?? 1) !== 1 || (adjustments.brightness ?? 0) !== 0
  );
}

function applyAdjustments(
  src: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): void {
  if (!hasAdjustments(adjustments)) return;
  cv.convertScaleAbs(
    src,
    src,
    adjustments?.contrast ?? 1,
    adjustments?.brightness ?? 0,
  );
}

/**
 * Alpha/beta for `convertScaleAbs` that stretch a single-channel histogram so
 * the given low/high percentiles map to 0/255 (CamScanner-style auto-contrast).
 */
function autoContrastParams(
  gray: CvMat,
  clipLow = 0.01,
  clipHigh = 0.99,
): { alpha: number; beta: number } {
  const hist = new Array<number>(256).fill(0);
  const { data } = gray;
  for (let i = 0; i < data.length; i++) hist[data[i]]++;

  const total = data.length;
  const lowCount = total * clipLow;
  const highCount = total * clipHigh;

  let cumulative = 0;
  let lowValue = 0;
  let highValue = 255;
  for (let v = 0; v < 256; v++) {
    cumulative += hist[v];
    if (cumulative <= lowCount) lowValue = v;
    if (cumulative <= highCount) highValue = v;
  }
  if (highValue <= lowValue) {
    lowValue = 0;
    highValue = 255;
  }
  const alpha = 255 / (highValue - lowValue);
  const beta = -lowValue * alpha;
  return { alpha, beta };
}

/**
 * Flatten uneven lighting: estimate the background with a large morphological
 * close, then divide the source by it. Takes a single-channel `Mat` and
 * returns a new grayscale `Mat` the caller must delete.
 */
export function removeShadow(
  gray: CvMat,
  cv: CvModule,
  kernelSize = 21,
): CvMat {
  const kSize = new cv.Size(kernelSize, kernelSize);
  const kernel = cv.getStructuringElement(MORPH_ELLIPSE, kSize);
  const background = new cv.Mat();
  const normalized = new cv.Mat();
  try {
    cv.morphologyEx(gray, background, MORPH_CLOSE, kernel);
    cv.divide(gray, background, normalized, 255);
    return normalized.clone();
  } finally {
    // `cv.Size` is a plain {width,height} value object — it has no delete().
    kernel.delete();
    background.delete();
    normalized.delete();
  }
}

/**
 * Local-contrast pop that keeps colour: run CLAHE on the L channel in LAB
 * space, leaving a/b untouched. This is the core of the "enhance" look —
 * text and edges gain punch without shifting hue. Modifies `rgb` in place.
 */
function claheOnLuminance(rgb: CvMat, cv: CvModule, clipLimit = 3.0): void {
  const lab = new cv.Mat();
  const channels = new cv.MatVector();
  const clahe = new cv.CLAHE(clipLimit, new cv.Size(8, 8));
  try {
    cv.cvtColor(rgb, lab, COLOR_RGB2LAB);
    cv.split(lab, channels);
    const l = channels.get(0);
    const enhanced = new cv.Mat();
    clahe.apply(l, enhanced);
    channels.set(0, enhanced);
    l.delete();
    cv.merge(channels, lab);
    cv.cvtColor(lab, rgb, COLOR_LAB2RGB);
  } finally {
    lab.delete();
    channels.delete();
    clahe.delete();
  }
}

/**
 * Lighten shadows with a gamma curve on the L channel (gamma < 1 brightens),
 * keeping colour. `cv.LUT` isn't in this OpenCV.js build, so the 256-entry
 * curve is applied with a JS pass over the single L channel. In place on `rgb`.
 */
function lightenLuminance(rgb: CvMat, cv: CvModule, gamma = 0.7): void {
  const table = new Uint8Array(256);
  for (let i = 0; i < 256; i++) {
    table[i] = Math.min(255, Math.round(255 * Math.pow(i / 255, gamma)));
  }
  const lab = new cv.Mat();
  const channels = new cv.MatVector();
  try {
    cv.cvtColor(rgb, lab, COLOR_RGB2LAB);
    cv.split(lab, channels);
    const l = channels.get(0);
    const curved = l.clone();
    for (let i = 0; i < curved.data.length; i++) {
      curved.data[i] = table[curved.data[i]];
    }
    channels.set(0, curved);
    l.delete();
    cv.merge(channels, lab);
    cv.cvtColor(lab, rgb, COLOR_LAB2RGB);
  } finally {
    lab.delete();
    channels.delete();
  }
}

/**
 * Unsharp mask: sharpen `src` in place (`src = src*(1+amount) - blur*amount`).
 * A camera-app-style crispness pass that compensates for the soft frames the
 * browser capture pipeline produces. Works on 1- or 3-channel `Mat`s.
 */
function sharpen(src: CvMat, cv: CvModule, amount = 0.8): void {
  const blurred = new cv.Mat();
  try {
    // ksize (0,0) => derived from sigma; sigma ~2 targets fine document detail.
    const kSize = new cv.Size(0, 0);
    cv.GaussianBlur(src, blurred, kSize, 2);
    cv.addWeighted(src, 1 + amount, blurred, -amount, 0, src);
  } finally {
    blurred.delete();
  }
}

/** White-balance (gray-world) + auto-contrast + gentle saturation boost. */
function magicColor(
  rgba: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): CvMat {
  const rgb = new cv.Mat();
  const channels = new cv.MatVector();
  const gray = new cv.Mat();
  const hsv = new cv.Mat();
  const hsvChannels = new cv.MatVector();
  const out = new cv.Mat();
  try {
    cv.cvtColor(rgba, rgb, COLOR_RGBA2RGB);

    // Gray-world white balance: scale each channel so their means match.
    cv.split(rgb, channels);
    const means: number[] = [];
    for (let c = 0; c < 3; c++) {
      const ch = channels.get(c);
      let sum = 0;
      for (let i = 0; i < ch.data.length; i++) sum += ch.data[i];
      means.push(sum / ch.data.length || 1);
    }
    const grayMean = (means[0] + means[1] + means[2]) / 3;
    for (let c = 0; c < 3; c++) {
      const ch = channels.get(c);
      const scaled = new cv.Mat();
      // Clamp the per-channel gain so a strong colour cast can't blow the
      // white balance out into an unnatural tint.
      const gain = Math.min(Math.max(grayMean / means[c], 0.75), 1.35);
      cv.convertScaleAbs(ch, scaled, gain, 0);
      channels.set(c, scaled);
      ch.delete();
    }
    cv.merge(channels, rgb);

    // Local-contrast pop (LAB CLAHE) — the "enhance/Melhorar" look.
    claheOnLuminance(rgb, cv, 3.0);

    // Auto-contrast driven by the luminance histogram (white-point stretch).
    cv.cvtColor(rgb, gray, COLOR_RGBA2GRAY);
    const { alpha, beta } = autoContrastParams(gray);
    cv.convertScaleAbs(rgb, rgb, alpha, beta);

    // Gentle saturation boost in HSV (configurable, softer default).
    const saturation = adjustments?.saturation ?? 1.15;
    cv.cvtColor(rgb, hsv, COLOR_RGB2HSV);
    cv.split(hsv, hsvChannels);
    const sat = hsvChannels.get(1);
    const boosted = new cv.Mat();
    cv.convertScaleAbs(sat, boosted, saturation, 0);
    hsvChannels.set(1, boosted);
    sat.delete();
    cv.merge(hsvChannels, hsv);
    cv.cvtColor(hsv, rgb, COLOR_HSV2RGB);

    sharpen(rgb, cv);
    applyAdjustments(rgb, cv, adjustments);
    cv.cvtColor(rgb, out, COLOR_RGB2RGBA);
    return out.clone();
  } finally {
    rgb.delete();
    channels.delete();
    gray.delete();
    hsv.delete();
    hsvChannels.delete();
    out.delete();
  }
}

/**
 * Shadow-flattened colour document: per-channel illumination normalisation
 * that keeps colour (stamps, signatures, letterheads, photos) while lifting
 * shadows, with a gentle saturation boost. Softer than magicColor.
 */
function colorDocument(
  rgba: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): CvMat {
  const rgb = new cv.Mat();
  const gray = new cv.Mat();
  const background = new cv.Mat();
  const channels = new cv.MatVector();
  const hsv = new cv.Mat();
  const hsvChannels = new cv.MatVector();
  const out = new cv.Mat();
  let kernel: CvMat | null = null;
  try {
    cv.cvtColor(rgba, rgb, COLOR_RGBA2RGB);
    cv.cvtColor(rgba, gray, COLOR_RGBA2GRAY);

    // Estimate the illumination background from luminance, then divide each
    // colour channel by it so lighting flattens but colour ratios survive.
    const kSize = new cv.Size(21, 21);
    kernel = cv.getStructuringElement(MORPH_ELLIPSE, kSize);
    cv.morphologyEx(gray, background, MORPH_CLOSE, kernel);
    cv.split(rgb, channels);
    for (let c = 0; c < 3; c++) {
      const ch = channels.get(c);
      const normalized = new cv.Mat();
      cv.divide(ch, background, normalized, 255);
      channels.set(c, normalized);
      ch.delete();
    }
    cv.merge(channels, rgb);

    // Softer local-contrast pop than magicColor — keeps the natural look.
    claheOnLuminance(rgb, cv, 2.0);

    // Gentle saturation lift (configurable).
    const saturation = adjustments?.saturation ?? 1.1;
    cv.cvtColor(rgb, hsv, COLOR_RGB2HSV);
    cv.split(hsv, hsvChannels);
    const sat = hsvChannels.get(1);
    const boosted = new cv.Mat();
    cv.convertScaleAbs(sat, boosted, saturation, 0);
    hsvChannels.set(1, boosted);
    sat.delete();
    cv.merge(hsvChannels, hsv);
    cv.cvtColor(hsv, rgb, COLOR_HSV2RGB);

    sharpen(rgb, cv);
    applyAdjustments(rgb, cv, adjustments);
    cv.cvtColor(rgb, out, COLOR_RGB2RGBA);
    return out.clone();
  } finally {
    rgb.delete();
    gray.delete();
    background.delete();
    channels.delete();
    hsv.delete();
    hsvChannels.delete();
    out.delete();
    kernel?.delete();
  }
}

/**
 * Lighten: brighten shadows with a gentle gamma curve on luminance while
 * keeping colour — good for underexposed or shadowed captures. A light sharpen
 * keeps text legible.
 */
function clarear(
  rgba: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): CvMat {
  const rgb = new cv.Mat();
  const out = new cv.Mat();
  try {
    cv.cvtColor(rgba, rgb, COLOR_RGBA2RGB);
    lightenLuminance(rgb, cv, 0.7);
    sharpen(rgb, cv, 0.4);
    applyAdjustments(rgb, cv, adjustments);
    cv.cvtColor(rgb, out, COLOR_RGB2RGBA);
    return out.clone();
  } finally {
    rgb.delete();
    out.delete();
  }
}

/** Grayscale + auto-contrast, returned as an RGBA `Mat`. */
function grayscale(
  rgba: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): CvMat {
  const gray = new cv.Mat();
  const out = new cv.Mat();
  try {
    cv.cvtColor(rgba, gray, COLOR_RGBA2GRAY);
    const { alpha, beta } = autoContrastParams(gray);
    cv.convertScaleAbs(gray, gray, alpha, beta);
    sharpen(gray, cv);
    applyAdjustments(gray, cv, adjustments);
    cv.cvtColor(gray, out, COLOR_GRAY2RGBA);
    return out.clone();
  } finally {
    gray.delete();
    out.delete();
  }
}

/** Shadow removal + adaptive threshold for crisp bilevel document text. */
function blackAndWhite(
  rgba: CvMat,
  cv: CvModule,
  adjustments?: EnhanceAdjustments,
): CvMat {
  const gray = new cv.Mat();
  let flattened: CvMat | null = null;
  const denoised = new cv.Mat();
  const binary = new cv.Mat();
  const out = new cv.Mat();
  try {
    cv.cvtColor(rgba, gray, COLOR_RGBA2GRAY);
    applyAdjustments(gray, cv, adjustments);
    flattened = removeShadow(gray, cv);
    // Median blur kills salt-and-pepper speckle so the threshold stays clean.
    cv.medianBlur(flattened, denoised, 3);
    // Larger block smooths the local threshold; C is user-tunable (higher =
    // cleaner/whiter background, lower = more ink retained).
    const c = adjustments?.bwStrength ?? 12;
    cv.adaptiveThreshold(
      denoised,
      binary,
      255,
      ADAPTIVE_THRESH_GAUSSIAN_C,
      THRESH_BINARY,
      25,
      c,
    );
    cv.cvtColor(binary, out, COLOR_GRAY2RGBA);
    return out.clone();
  } finally {
    gray.delete();
    flattened?.delete();
    denoised.delete();
    binary.delete();
    out.delete();
  }
}

/**
 * Apply an enhancement filter to `ImageData`, returning enhanced `ImageData`.
 * Pure and React-free so it can run on the main thread or in a Web Worker.
 */
export function enhanceImageData(
  input: ImageData,
  filter: EnhanceFilter,
  adjustments?: EnhanceAdjustments,
): ImageData {
  if (filter === "original" && !hasAdjustments(adjustments)) return input;

  const cv = getCv();
  const src = cv.matFromImageData(input);
  let result: CvMat | null = null;
  try {
    switch (filter) {
      case "magicColor":
        result = magicColor(src, cv, adjustments);
        break;
      case "colorDocument":
        result = colorDocument(src, cv, adjustments);
        break;
      case "clarear":
        result = clarear(src, cv, adjustments);
        break;
      case "grayscale":
        result = grayscale(src, cv, adjustments);
        break;
      case "blackAndWhite":
        result = blackAndWhite(src, cv, adjustments);
        break;
      case "original": {
        result = src.clone();
        applyAdjustments(result, cv, adjustments);
        break;
      }
    }
    return new ImageData(
      new Uint8ClampedArray(result.data),
      result.cols,
      result.rows,
    );
  } finally {
    src.delete();
    result?.delete();
  }
}

/** Read `ImageData` out of a canvas (full, or scaled down to `targetWidth`). */
export function canvasToImageData(
  canvas: HTMLCanvasElement,
  targetWidth?: number,
): ImageData {
  const scale =
    targetWidth && canvas.width > targetWidth ? targetWidth / canvas.width : 1;
  const width = Math.round(canvas.width * scale);
  const height = Math.round(canvas.height * scale);

  const work = document.createElement("canvas");
  work.width = width;
  work.height = height;
  const ctx = work.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("Cannot create 2D context");
  ctx.drawImage(canvas, 0, 0, width, height);
  return ctx.getImageData(0, 0, width, height);
}

/** Load an image element from a data URL. */
export function loadImage(dataUrl: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("Failed to load image"));
    img.src = dataUrl;
  });
}

/** Draw an image element onto a fresh canvas at its natural size. */
export function imageToCanvas(img: HTMLImageElement): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.width = img.naturalWidth;
  canvas.height = img.naturalHeight;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("Cannot create 2D context");
  ctx.drawImage(img, 0, 0);
  return canvas;
}

/** Encode `ImageData` to a data URL, PNG for bilevel filters, JPEG otherwise. */
export function imageDataToDataUrl(
  imageData: ImageData,
  filter: EnhanceFilter,
): string {
  const canvas = document.createElement("canvas");
  canvas.width = imageData.width;
  canvas.height = imageData.height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Cannot create 2D context");
  ctx.putImageData(imageData, 0, 0);
  // B&W stays PNG (bilevel — JPEG would ring around text). Colour/grey use JPEG
  // at 0.82: near-visually-lossless for documents but far smaller than 0.92.
  return filter === "blackAndWhite"
    ? canvas.toDataURL("image/png")
    : canvas.toDataURL("image/jpeg", 0.82);
}
