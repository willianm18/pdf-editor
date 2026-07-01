import apiClient from "@app/services/apiClient";

export interface TransparencyOptions {
  lowerBound?: { r: number; g: number; b: number };
  upperBound?: { r: number; g: number; b: number };
  autoDetectCorner?: boolean;
  tolerance?: number;
}

/**
 * Removes the background from an image using the rembg AI service (backend
 * /api/v1/misc/remove-image-background), returning a data URL of the resulting
 * PNG with a transparent background.
 *
 * `options` is kept for backward compatibility with existing callers but is
 * no longer used: rembg detects the subject via its model instead of a
 * color-key range, so there is no lower/upper bound or corner-sampling to
 * configure.
 */
export async function removeWhiteBackground(
  imageFile: File | string,
  _options: TransparencyOptions = {},
): Promise<string> {
  const file = await toFile(imageFile);

  const formData = new FormData();
  formData.append("imageFile", file);

  const response = await apiClient.post<Blob>(
    "/api/v1/misc/remove-image-background",
    formData,
    { responseType: "blob" },
  );

  return blobToDataUrl(response.data);
}

async function toFile(imageFile: File | string): Promise<File> {
  if (typeof imageFile !== "string") {
    return imageFile;
  }

  const response = await fetch(imageFile);
  const blob = await response.blob();
  return new File([blob], "image", { type: blob.type || "image/png" });
}

function blobToDataUrl(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = () => reject(reader.error ?? new Error("Failed to read image blob"));
    reader.readAsDataURL(blob);
  });
}
