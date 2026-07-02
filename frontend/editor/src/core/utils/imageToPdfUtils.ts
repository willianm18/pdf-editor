import { getPdfiumModule, saveRawDocument } from "@app/services/pdfiumService";
import { copyRgbaToBgraHeap } from "@app/utils/pdfiumBitmapUtils";
import type { WrappedPdfiumModule } from "@embedpdf/pdfium";

// Emscripten runtime members not surfaced by @embedpdf/pdfium's public typings.
interface PdfiumHeapRuntime {
  HEAPU8: Uint8Array;
}

export interface ImageToPdfOptions {
  imageResolution?: "full" | "reduced";
  pageFormat?: "keep" | "A4" | "letter";
  stretchToFit?: boolean;
}

// Standard page sizes in PDF points (72 dpi)
const PAGE_SIZES = {
  A4: [595.276, 841.89] as [number, number],
  Letter: [612, 792] as [number, number],
};

/**
 * Convert an image file to a PDF file using PDFium WASM.
 */
export async function convertImageToPdf(
  imageFile: File,
  options: ImageToPdfOptions = {},
): Promise<File> {
  const {
    imageResolution = "full",
    pageFormat = "A4",
    stretchToFit = false,
  } = options;

  try {
    const m = await getPdfiumModule();

    // Read the image file
    let imageBlob: Blob = imageFile;

    // Apply image resolution reduction if requested
    if (imageResolution === "reduced") {
      imageBlob = await reduceImageResolution(imageFile, 1200);
    }

    // JPEG input can be embedded losslessly as DCTDecode (keeping the original
    // compressed bytes) instead of re-encoding a decoded RGBA bitmap, which
    // would balloon the PDF far beyond the source file. Other formats still go
    // through the bitmap path below.
    const isJpeg = imageBlob.type === "image/jpeg";

    // Decode image to RGBA pixels via canvas. For JPEG we only need the pixel
    // dimensions for page sizing/placement, not the RGBA payload itself.
    const decoded = await decodeImageToRgba(imageBlob);
    if (!decoded) {
      throw new Error("Failed to decode image");
    }

    const { rgba, width: imageWidth, height: imageHeight } = decoded;

    // Determine page dimensions
    let pageWidth: number;
    let pageHeight: number;

    if (pageFormat === "keep") {
      pageWidth = imageWidth;
      pageHeight = imageHeight;
    } else if (pageFormat === "letter") {
      [pageWidth, pageHeight] = PAGE_SIZES.Letter;
    } else {
      [pageWidth, pageHeight] = PAGE_SIZES.A4;
    }

    // Adjust orientation to match image
    if (pageFormat !== "keep") {
      const imageIsLandscape = imageWidth > imageHeight;
      const pageIsLandscape = pageWidth > pageHeight;
      if (imageIsLandscape !== pageIsLandscape) {
        [pageWidth, pageHeight] = [pageHeight, pageWidth];
      }
    }

    // Calculate image placement
    let drawX: number;
    let drawY: number;
    let drawWidth: number;
    let drawHeight: number;

    if (stretchToFit || pageFormat === "keep") {
      drawX = 0;
      drawY = 0;
      drawWidth = pageWidth;
      drawHeight = pageHeight;
    } else {
      const imageAspectRatio = imageWidth / imageHeight;
      const pageAspectRatio = pageWidth / pageHeight;

      if (imageAspectRatio > pageAspectRatio) {
        drawWidth = pageWidth;
        drawHeight = pageWidth / imageAspectRatio;
        drawX = 0;
        drawY = (pageHeight - drawHeight) / 2;
      } else {
        drawHeight = pageHeight;
        drawWidth = pageHeight * imageAspectRatio;
        drawY = 0;
        drawX = (pageWidth - drawWidth) / 2;
      }
    }

    // Create new PDF document
    const docPtr = m.FPDF_CreateNewDocument();
    if (!docPtr) throw new Error("PDFium: failed to create document");

    try {
      // Create a page
      const pagePtr = m.FPDFPage_New(docPtr, 0, pageWidth, pageHeight);
      if (!pagePtr) throw new Error("PDFium: failed to create page");

      // Create image page object
      const imageObjPtr = m.FPDFPageObj_NewImageObj(docPtr);
      if (!imageObjPtr) {
        throw new Error("PDFium: failed to create image object");
      }

      const jpegEmbedded =
        isJpeg && (await embedJpegInline(m, imageObjPtr, imageBlob));

      if (!jpegEmbedded) {
        // Bitmap path (non-JPEG, or graceful fallback if the inline JPEG
        // embed was unavailable at runtime).
        const bitmapPtr = m.FPDFBitmap_Create(imageWidth, imageHeight, 1);
        if (!bitmapPtr) {
          m.FPDFPageObj_Destroy(imageObjPtr);
          throw new Error("PDFium: failed to create bitmap");
        }

        const bufferPtr = m.FPDFBitmap_GetBuffer(bitmapPtr);
        const stride = m.FPDFBitmap_GetStride(bitmapPtr);

        // Bulk RGBA → BGRA copy via shared utility
        copyRgbaToBgraHeap(m, rgba, bufferPtr, imageWidth, imageHeight, stride);

        const setBitmapOk = m.FPDFImageObj_SetBitmap(
          pagePtr,
          0,
          imageObjPtr,
          bitmapPtr,
        );
        m.FPDFBitmap_Destroy(bitmapPtr);

        if (!setBitmapOk) {
          m.FPDFPageObj_Destroy(imageObjPtr);
          throw new Error("PDFium: failed to set bitmap on image object");
        }
      }

      // Set transformation matrix: scale + translate
      // FS_MATRIX: {a, b, c, d, e, f} — 6 floats
      const matrixPtr = m.pdfium.wasmExports.malloc(6 * 4);
      m.pdfium.setValue(matrixPtr, drawWidth, "float"); // a = scaleX
      m.pdfium.setValue(matrixPtr + 4, 0, "float"); // b
      m.pdfium.setValue(matrixPtr + 8, 0, "float"); // c
      m.pdfium.setValue(matrixPtr + 12, drawHeight, "float"); // d = scaleY
      m.pdfium.setValue(matrixPtr + 16, drawX, "float"); // e = translateX
      m.pdfium.setValue(matrixPtr + 20, drawY, "float"); // f = translateY

      const setMatrixOk = m.FPDFPageObj_SetMatrix(imageObjPtr, matrixPtr);
      m.pdfium.wasmExports.free(matrixPtr);

      if (!setMatrixOk) {
        m.FPDFPageObj_Destroy(imageObjPtr);
        throw new Error("PDFium: failed to set image matrix");
      }

      // Insert image into page
      m.FPDFPage_InsertObject(pagePtr, imageObjPtr);

      // Generate page content stream
      m.FPDFPage_GenerateContent(pagePtr);
      m.FPDF_ClosePage(pagePtr);

      // Save document
      const pdfBytes = await saveRawDocument(docPtr);
      const pdfFilename = imageFile.name.replace(/\.[^.]+$/, ".pdf");

      return new File([pdfBytes], pdfFilename, { type: "application/pdf" });
    } finally {
      m.FPDF_CloseDocument(docPtr);
    }
  } catch (error) {
    console.error("Error converting image to PDF:", error);
    throw new Error(
      `Failed to convert image to PDF: ${error instanceof Error ? error.message : "Unknown error"}`,
      {
        cause: error,
      },
    );
  }
}

/**
 * Attach the original JPEG bytes to an image object as DCTDecode via
 * `FPDFImageObj_LoadJpegFileInline`, preserving the source file's compression
 * and quality instead of embedding a decoded RGBA bitmap.
 *
 * Returns `true` on success. Returns `false` (rather than throwing) if the
 * inline-JPEG API path is unusable at runtime, so the caller can fall back to
 * the bitmap path — image→PDF conversion must never break.
 *
 * `FPDF_FILEACCESS` (WASM 32-bit, 12 bytes):
 *   offset 0 → m_FileLen (u32)
 *   offset 4 → m_GetBlock function pointer
 *   offset 8 → m_Param (void*, unused — the buffer is captured by the closure)
 */
async function embedJpegInline(
  m: WrappedPdfiumModule,
  imageObjPtr: number,
  jpegBlob: Blob,
): Promise<boolean> {
  const jpegBytes = new Uint8Array(await jpegBlob.arrayBuffer());
  const heap = () => (m.pdfium as typeof m.pdfium & PdfiumHeapRuntime).HEAPU8;

  let bufferPtr = 0;
  let fileAccessPtr = 0;
  let getBlockFn = 0;
  try {
    bufferPtr = m.pdfium.wasmExports.malloc(jpegBytes.length);
    if (!bufferPtr) return false;
    heap().set(jpegBytes, bufferPtr);

    // m_GetBlock: int (*)(void* param, unsigned long position,
    //                     unsigned char* pBuf, unsigned long size)
    const getBlock = (
      _param: number,
      position: number,
      pBuf: number,
      size: number,
    ): number => {
      heap().copyWithin(
        pBuf,
        bufferPtr + position,
        bufferPtr + position + size,
      );
      return 1;
    };
    getBlockFn = m.pdfium.addFunction(getBlock, "iiiii");

    fileAccessPtr = m.pdfium.wasmExports.malloc(12);
    if (!fileAccessPtr) return false;
    m.pdfium.setValue(fileAccessPtr, jpegBytes.length, "i32"); // m_FileLen
    m.pdfium.setValue(fileAccessPtr + 4, getBlockFn, "i32"); // m_GetBlock
    m.pdfium.setValue(fileAccessPtr + 8, 0, "i32"); // m_Param

    // pages null / count 0: the object is not attached to any page yet.
    // The Inline variant copies the data during this call, so the JPEG buffer
    // is safe to free immediately afterwards.
    return m.FPDFImageObj_LoadJpegFileInline(0, 0, imageObjPtr, fileAccessPtr);
  } catch (error) {
    console.warn(
      "PDFium inline JPEG embed unavailable, falling back to bitmap:",
      error,
    );
    return false;
  } finally {
    if (bufferPtr) m.pdfium.wasmExports.free(bufferPtr);
    if (fileAccessPtr) m.pdfium.wasmExports.free(fileAccessPtr);
    if (getBlockFn) m.pdfium.removeFunction(getBlockFn);
  }
}

/**
 * Decode an image Blob to RGBA pixel data via canvas.
 */
function decodeImageToRgba(
  imageBlob: Blob,
): Promise<{ rgba: Uint8Array; width: number; height: number } | null> {
  return new Promise((resolve) => {
    const img = new Image();
    const url = URL.createObjectURL(imageBlob);

    img.onload = () => {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = img.width;
        canvas.height = img.height;
        const ctx = canvas.getContext("2d");
        if (!ctx) {
          URL.revokeObjectURL(url);
          resolve(null);
          return;
        }
        ctx.drawImage(img, 0, 0);
        const imageData = ctx.getImageData(0, 0, canvas.width, canvas.height);
        URL.revokeObjectURL(url);
        resolve({
          rgba: new Uint8Array(imageData.data.buffer),
          width: canvas.width,
          height: canvas.height,
        });
      } catch {
        URL.revokeObjectURL(url);
        resolve(null);
      }
    };

    img.onerror = () => {
      URL.revokeObjectURL(url);
      resolve(null);
    };

    img.src = url;
  });
}

/**
 * Reduce image resolution to a maximum dimension
 */
async function reduceImageResolution(
  imageFile: File,
  maxDimension: number,
): Promise<File> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const url = URL.createObjectURL(imageFile);

    img.onload = () => {
      try {
        const { width, height } = img;

        if (width <= maxDimension && height <= maxDimension) {
          URL.revokeObjectURL(url);
          resolve(imageFile);
          return;
        }

        let newWidth: number;
        let newHeight: number;

        if (width > height) {
          newWidth = maxDimension;
          newHeight = (height / width) * maxDimension;
        } else {
          newHeight = maxDimension;
          newWidth = (width / height) * maxDimension;
        }

        const canvas = document.createElement("canvas");
        canvas.width = newWidth;
        canvas.height = newHeight;

        const ctx = canvas.getContext("2d");
        if (!ctx) throw new Error("Failed to get canvas context");
        ctx.drawImage(img, 0, 0, newWidth, newHeight);

        const outputType = imageFile.type.startsWith("image/")
          ? imageFile.type
          : "image/jpeg";

        canvas.toBlob(
          (blob) => {
            if (!blob) {
              reject(new Error("Failed to convert canvas to blob"));
              return;
            }
            const reducedFile = new File([blob], imageFile.name, {
              type: outputType,
            });
            URL.revokeObjectURL(url);
            resolve(reducedFile);
          },
          outputType,
          0.9,
        );
      } catch (error) {
        URL.revokeObjectURL(url);
        reject(error);
      }
    };

    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Failed to load image"));
    };

    img.src = url;
  });
}

/**
 * Check if a file is an image
 */
export function isImageFile(file: File): boolean {
  return file.type.startsWith("image/");
}
