import { useState, useRef, useEffect, useCallback } from "react";
import { useSearchParams, useNavigate } from "react-router-dom";
import {
  Box,
  Button,
  Stack,
  Text,
  Group,
  Alert,
  Progress,
  Switch,
  Card,
  Slider,
} from "@mantine/core";
import { useTranslation } from "react-i18next";
import { LogoIcon } from "@app/components/shared/LogoIcon";
import { Wordmark } from "@app/components/shared/Wordmark";
import ErrorRoundedIcon from "@mui/icons-material/ErrorRounded";
import InfoRoundedIcon from "@mui/icons-material/InfoRounded";
import PhotoCameraRoundedIcon from "@mui/icons-material/PhotoCameraRounded";
import UploadRoundedIcon from "@mui/icons-material/UploadRounded";
import AddPhotoAlternateRoundedIcon from "@mui/icons-material/AddPhotoAlternateRounded";
import CheckCircleRoundedIcon from "@mui/icons-material/CheckCircleRounded";
import {
  loadJscanify,
  type JscanifyCornerPoints,
  type JscanifyScanner,
} from "@app/utils/loadJscanify";
import apiClient from "@app/services/apiClient";
import {
  type EnhanceFilter,
  type EnhanceAdjustments,
  enhanceImageData,
  canvasToImageData,
  imageDataToDataUrl,
  loadImage,
  imageToCanvas,
} from "@app/utils/imageEnhance";

// Use the configured API base (e.g. api.stirling.com), not the page origin.
const API_BASE = (apiClient.defaults.baseURL ?? "").replace(/\/+$/, "");

// Experimental camera controls (W3C Image Capture / MediaStream extensions) that
// are not yet part of the standard DOM lib typings but are widely shipped on
// mobile browsers and required for document scanning.
declare global {
  interface MediaTrackCapabilities {
    focusMode?: string[];
    exposureMode?: string[];
    torch?: boolean;
  }
  interface MediaTrackConstraintSet {
    focusMode?: ConstrainDOMString;
    exposureMode?: ConstrainDOMString;
    torch?: ConstrainBoolean;
  }
}

interface Point {
  x: number;
  y: number;
}

const CORNER_KEYS = [
  "topLeftCorner",
  "topRightCorner",
  "bottomRightCorner",
  "bottomLeftCorner",
] as const;
type CornerKey = (typeof CORNER_KEYS)[number];

/** Enhancement filters shown in the preview strip, in display order. */
const FILTER_ORDER: EnhanceFilter[] = [
  "magicColor",
  "grayscale",
  "blackAndWhite",
  "original",
];

/** Width used for the instant filter thumbnails; full res is used on confirm. */
const THUMB_WIDTH = 120;

/** Width cap for the on-screen preview; full res is only used on confirm. */
const PREVIEW_WIDTH = 900;

/** Fallback quadrilateral (5% inset) used when automatic edge detection fails. */
function defaultCorners(width: number, height: number): JscanifyCornerPoints {
  const marginX = width * 0.05;
  const marginY = height * 0.05;
  return {
    topLeftCorner: { x: marginX, y: marginY },
    topRightCorner: { x: width - marginX, y: marginY },
    bottomLeftCorner: { x: marginX, y: height - marginY },
    bottomRightCorner: { x: width - marginX, y: height - marginY },
  };
}

interface CornerAdjustScreenProps {
  dataUrl: string;
  naturalWidth: number;
  naturalHeight: number;
  initialCorners: JscanifyCornerPoints;
  processing: boolean;
  onConfirm: (corners: JscanifyCornerPoints) => void;
  onCancel: () => void;
}

/**
 * Full-screen overlay allowing the user to drag the 4 detected corners of the
 * document before it gets warped/cropped. Acts as the fallback when automatic
 * edge detection (jscanify) picks the wrong contour or none at all.
 */
function CornerAdjustScreen({
  dataUrl,
  naturalWidth,
  naturalHeight,
  initialCorners,
  processing,
  onConfirm,
  onCancel,
}: CornerAdjustScreenProps) {
  const { t } = useTranslation();
  const containerRef = useRef<HTMLDivElement>(null);
  const [corners, setCorners] = useState<Record<CornerKey, Point>>(
    initialCorners as Record<CornerKey, Point>,
  );
  const [displayRect, setDisplayRect] = useState({
    width: 0,
    height: 0,
    offsetX: 0,
    offsetY: 0,
  });
  const draggingRef = useRef<CornerKey | null>(null);

  useEffect(() => {
    const updateRect = () => {
      const container = containerRef.current;
      if (!container) return;
      const { width: cw, height: ch } = container.getBoundingClientRect();
      const imageAspect = naturalWidth / naturalHeight;
      const containerAspect = cw / ch;
      let width: number;
      let height: number;
      if (imageAspect > containerAspect) {
        width = cw;
        height = cw / imageAspect;
      } else {
        height = ch;
        width = ch * imageAspect;
      }
      setDisplayRect({
        width,
        height,
        offsetX: (cw - width) / 2,
        offsetY: (ch - height) / 2,
      });
    };

    updateRect();
    window.addEventListener("resize", updateRect);
    return () => window.removeEventListener("resize", updateRect);
  }, [naturalWidth, naturalHeight]);

  const toDisplay = useCallback(
    (point: Point): Point => ({
      x: displayRect.offsetX + (point.x / naturalWidth) * displayRect.width,
      y: displayRect.offsetY + (point.y / naturalHeight) * displayRect.height,
    }),
    [displayRect, naturalWidth, naturalHeight],
  );

  const toNatural = useCallback(
    (clientPoint: Point): Point => {
      const container = containerRef.current;
      if (!container || displayRect.width === 0 || displayRect.height === 0) {
        return clientPoint;
      }
      const rect = container.getBoundingClientRect();
      const localX = clientPoint.x - rect.left - displayRect.offsetX;
      const localY = clientPoint.y - rect.top - displayRect.offsetY;
      return {
        x: Math.min(
          Math.max((localX / displayRect.width) * naturalWidth, 0),
          naturalWidth,
        ),
        y: Math.min(
          Math.max((localY / displayRect.height) * naturalHeight, 0),
          naturalHeight,
        ),
      };
    },
    [displayRect, naturalWidth, naturalHeight],
  );

  const handlePointerDown = useCallback(
    (key: CornerKey) => (e: React.PointerEvent) => {
      e.preventDefault();
      (e.target as Element).setPointerCapture(e.pointerId);
      draggingRef.current = key;
    },
    [],
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent) => {
      const key = draggingRef.current;
      if (!key) return;
      const natural = toNatural({ x: e.clientX, y: e.clientY });
      setCorners((prev) => ({ ...prev, [key]: natural }));
    },
    [toNatural],
  );

  const handlePointerUp = useCallback(() => {
    draggingRef.current = null;
  }, []);

  const displayed: Record<CornerKey, Point> = {
    topLeftCorner: toDisplay(corners.topLeftCorner),
    topRightCorner: toDisplay(corners.topRightCorner),
    bottomRightCorner: toDisplay(corners.bottomRightCorner),
    bottomLeftCorner: toDisplay(corners.bottomLeftCorner),
  };

  const polygonPoints = CORNER_KEYS.map(
    (key) => `${displayed[key].x},${displayed[key].y}`,
  ).join(" ");

  return (
    <Box
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 1000,
        background: "var(--bg-background)",
        display: "flex",
        flexDirection: "column",
        height: "100dvh",
      }}
    >
      <Box
        ref={containerRef}
        style={{
          position: "relative",
          flex: 1,
          background: "#000",
          overflow: "hidden",
          touchAction: "none",
        }}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        <img
          src={dataUrl}
          alt="Captured document"
          style={{
            width: "100%",
            height: "100%",
            objectFit: "contain",
            display: "block",
            pointerEvents: "none",
          }}
        />
        <svg
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            width: "100%",
            height: "100%",
            pointerEvents: "none",
          }}
        >
          <polygon
            points={polygonPoints}
            fill="rgba(0, 255, 0, 0.15)"
            stroke="#00FF00"
            strokeWidth={3}
          />
        </svg>
        {CORNER_KEYS.map((key) => (
          <Box
            key={key}
            onPointerDown={handlePointerDown(key)}
            style={{
              position: "absolute",
              left: displayed[key].x - 16,
              top: displayed[key].y - 16,
              width: 32,
              height: 32,
              borderRadius: "50%",
              background: "rgba(0, 255, 0, 0.9)",
              border: "2px solid white",
              touchAction: "none",
              cursor: "grab",
            }}
          />
        ))}
      </Box>

      <Box
        style={{
          backgroundColor: "var(--bg-toolbar)",
          borderTop: "1px solid var(--border-subtle)",
          padding: "0.75rem 1rem",
        }}
      >
        <Stack gap="sm">
          <Text size="xs" c="dimmed" ta="center">
            {t(
              "mobileScanner.adjustCornersHint",
              "Drag the corners to match the document edges",
            )}
          </Text>
          <Group grow>
            <Button
              variant="default"
              onClick={onCancel}
              size="lg"
              disabled={processing}
            >
              {t("mobileScanner.retake", "Retake")}
            </Button>
            <Button
              variant="filled"
              onClick={() =>
                onConfirm({
                  topLeftCorner: corners.topLeftCorner,
                  topRightCorner: corners.topRightCorner,
                  bottomLeftCorner: corners.bottomLeftCorner,
                  bottomRightCorner: corners.bottomRightCorner,
                })
              }
              size="lg"
              loading={processing}
            >
              {t("mobileScanner.confirmCrop", "Confirm")}
            </Button>
          </Group>
        </Stack>
      </Box>
    </Box>
  );
}

/**
 * MobileScannerPage
 *
 * Mobile-friendly page for capturing photos and uploading them to the backend server.
 * Accessed by scanning QR code from desktop.
 */
export default function MobileScannerPage() {
  const { t } = useTranslation();
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const sessionId = searchParams.get("session");

  const [mode, setMode] = useState<"choice" | "camera" | "file" | null>(
    "choice",
  );
  const [capturedImages, setCapturedImages] = useState<string[]>([]);
  const [currentPreview, setCurrentPreview] = useState<string | null>(null);
  // Un-filtered cropped capture; the displayed `currentPreview` is derived from
  // this plus the active filter/adjustments so switching filters is cheap.
  const [previewBase, setPreviewBase] = useState<string | null>(null);
  const [activeFilter, setActiveFilter] = useState<EnhanceFilter>("magicColor");
  const [brightness, setBrightness] = useState(0);
  const [contrast, setContrast] = useState(1);
  const [filterThumbs, setFilterThumbs] = useState<
    Partial<Record<EnhanceFilter, string>>
  >({});
  const [isUploading, setIsUploading] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [uploadSuccess, setUploadSuccess] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [cameraError, setCameraError] = useState<string | null>(null);
  const [autoEnhance, setAutoEnhance] = useState(true);
  const [isProcessing, setIsProcessing] = useState(false);
  const [openCvReady, setOpenCvReady] = useState(false);
  const [torchEnabled, setTorchEnabled] = useState(false);
  const [torchSupported, setTorchSupported] = useState(false);
  const [sessionValid, setSessionValid] = useState<boolean | null>(null); // null = checking, true = valid, false = invalid
  const [sessionError, setSessionError] = useState<string | null>(null);
  const [loadingStatus, setLoadingStatus] = useState<string>("Initializing...");
  const [cameraReady, setCameraReady] = useState(false);
  const [adjustState, setAdjustState] = useState<{
    dataUrl: string;
    width: number;
    height: number;
    corners: JscanifyCornerPoints;
  } | null>(null);

  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const highlightCanvasRef = useRef<HTMLCanvasElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const scannerRef = useRef<JscanifyScanner | null>(null);
  const highlightIntervalRef = useRef<number | null>(null);

  // Detection resolution - extremely low for mobile performance
  const DETECTION_WIDTH = 160; // Ultra-low for real-time mobile detection
  // Higher-res detection used only once, at capture time (not per-frame),
  // so it can afford much more detail for a more accurate contour.
  const CAPTURE_DETECTION_WIDTH = 800;

  // Validate session on page load
  useEffect(() => {
    const validateSession = async () => {
      setLoadingStatus("Validating session...");
      if (!sessionId) {
        setSessionValid(false);
        setSessionError(
          t(
            "mobileScanner.noSessionMessage",
            "Session not found. Please try again.",
          ),
        );
        setLoadingStatus("Session validation failed");
        return;
      }

      try {
        const response = await fetch(
          `${API_BASE}/api/v1/mobile-scanner/validate-session/${sessionId}`,
        );

        if (response.ok) {
          const data = await response.json();
          if (data.valid) {
            setSessionValid(true);
            setSessionError(null);
            // Don't set status here - let camera/detection effects control status from now on
            console.log("Session validated successfully:", data);
          } else {
            setSessionValid(false);
            setSessionError(
              t(
                "mobileScanner.sessionExpired",
                "This session has expired. Please refresh and try again.",
              ),
            );
            setLoadingStatus("Session expired ✗");
          }
        } else {
          setSessionValid(false);
          setSessionError(
            t(
              "mobileScanner.sessionNotFound",
              "Session not found. Please refresh and try again.",
            ),
          );
          setLoadingStatus("Session not found ✗");
        }
      } catch (err) {
        console.error("Failed to validate session:", err);
        setSessionValid(false);
        setSessionError(
          t(
            "mobileScanner.sessionValidationError",
            "Unable to verify session. Please try again.",
          ),
        );
        setLoadingStatus("Session validation error: " + (err as Error).message);
      }
    };

    validateSession();
  }, [sessionId, t]);

  useEffect(() => {
    let cancelled = false;

    loadJscanify({
      onStatus: (status) => {
        if (!cancelled) setLoadingStatus(status);
      },
    })
      .then(() => {
        if (cancelled) return;
        try {
          scannerRef.current = new window.jscanify!();
          setOpenCvReady(true);
          console.log("✓ jscanify initialized with OpenCV");
        } catch (err) {
          setLoadingStatus("jscanify init failed ✗");
          console.error("Failed to initialize jscanify:", err);
        }
      })
      .catch((err) => {
        if (cancelled) return;
        setLoadingStatus(
          `Scanner library failed to load ✗: ${(err as Error).message}`,
        );
        console.error("Failed to load jscanify:", err);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  // Initialize camera
  useEffect(() => {
    console.log(
      `[Mobile Scanner] Camera effect triggered: mode=${mode}, cameraError=${cameraError}, currentPreview=${currentPreview}`,
    );

    if (mode === "camera" && !cameraError && !currentPreview) {
      console.log(
        "[Mobile Scanner] Camera effect: Starting camera initialization",
      );

      // Check if mediaDevices API is available (requires HTTPS or localhost)
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        const error =
          "MediaDevices API not available - requires HTTPS or localhost";
        console.error(error);
        setLoadingStatus("Camera API not available ✗");
        setCameraError(
          t(
            "mobileScanner.httpsRequired",
            "Camera access requires HTTPS or localhost. Please use HTTPS or access via localhost.",
          ),
        );
        setMode("file");
        return;
      }

      setLoadingStatus("Initializing camera...");

      console.log("[Mobile Scanner] Requesting camera permission...");
      navigator.mediaDevices
        .getUserMedia({
          video: {
            facingMode: "environment",
            // Request 1080p - good quality without going overboard
            width: { ideal: 1920, max: 1920 },
            height: { ideal: 1080, max: 1080 },
          },
          audio: false,
        })
        .then(async (stream) => {
          console.log(
            "[Mobile Scanner] Camera permission granted, stream received",
          );
          streamRef.current = stream;
          if (videoRef.current) {
            const video = videoRef.current;
            video.srcObject = stream;

            // Wait for video metadata to load before marking camera as ready
            const handleLoadedMetadata = () => {
              console.log(
                "[Mobile Scanner] Video metadata loaded, dimensions:",
                video.videoWidth,
                "x",
                video.videoHeight,
              );
              setLoadingStatus(
                `Camera ready: ${video.videoWidth}x${video.videoHeight} ✓`,
              );

              // Signal that camera is ready - this will trigger detection effect
              console.log("[Mobile Scanner] Setting cameraReady = true");
              setCameraReady(true);
            };

            // Check if metadata is already loaded
            if (video.readyState >= 1) {
              // HAVE_METADATA or greater
              handleLoadedMetadata();
            } else {
              // Wait for loadedmetadata event
              video.addEventListener("loadedmetadata", handleLoadedMetadata, {
                once: true,
              });
            }

            // Log actual resolution we got from stream settings
            const videoTrack = stream.getVideoTracks()[0];
            const settings = videoTrack.getSettings();
            console.log(
              "[Mobile Scanner] Camera stream settings:",
              settings.width,
              "x",
              settings.height,
            );

            // Configure camera capabilities for document scanning
            try {
              const capabilities = videoTrack.getCapabilities();
              const advanced: MediaTrackConstraintSet[] = [];

              // 1. Enable continuous autofocus
              if (
                capabilities.focusMode &&
                capabilities.focusMode.includes("continuous")
              ) {
                advanced.push({ focusMode: "continuous" });
                console.log("✓ Continuous autofocus enabled");
              }

              // 2. Enable continuous auto-exposure for varying lighting
              if (
                capabilities.exposureMode &&
                capabilities.exposureMode.includes("continuous")
              ) {
                advanced.push({ exposureMode: "continuous" });
                console.log("✓ Auto-exposure enabled");
              }

              // 3. Check if torch/flashlight is supported
              if (capabilities.torch) {
                setTorchSupported(true);
                console.log("✓ Torch/flashlight available");
              }

              // Apply all constraints
              if (advanced.length > 0) {
                await videoTrack.applyConstraints({ advanced });
              }
            } catch (err) {
              console.log("Could not configure camera features:", err);
            }
          }
        })
        .catch((err) => {
          console.error("Camera error:", err);
          setLoadingStatus("Camera access denied ✗");
          setCameraError(
            t(
              "mobileScanner.cameraAccessDenied",
              "Camera access denied. Please enable camera access.",
            ),
          );
          // Auto-switch to file upload if camera fails
          setMode("file");
        });
    }

    return () => {
      // Clean up stream when switching away from camera or showing preview
      if (streamRef.current) {
        streamRef.current.getTracks().forEach((track) => track.stop());
        streamRef.current = null;
      }
      // Stop highlighting when camera is stopped
      if (highlightIntervalRef.current) {
        clearInterval(highlightIntervalRef.current);
        highlightIntervalRef.current = null;
      }
      // Reset camera ready state
      setCameraReady(false);
    };
  }, [mode, cameraError, currentPreview, t]);

  // Real-time document highlighting on camera feed
  useEffect(() => {
    console.log(
      `[Mobile Scanner] Effect triggered: mode=${mode}, autoEnhance=${autoEnhance}, openCvReady=${openCvReady}, cameraReady=${cameraReady}, currentPreview=${currentPreview}`,
    );

    // Show helpful status if detection is enabled but waiting for dependencies
    if (mode === "camera" && autoEnhance && !currentPreview && !adjustState) {
      if (!openCvReady) {
        setLoadingStatus("Waiting for OpenCV...");
      } else if (!cameraReady) {
        setLoadingStatus("Waiting for camera...");
      }
    }

    if (
      mode === "camera" &&
      autoEnhance &&
      openCvReady &&
      cameraReady &&
      scannerRef.current &&
      !currentPreview &&
      !adjustState
    ) {
      const startHighlighting = () => {
        console.log("[Mobile Scanner] startHighlighting() called");

        if (!videoRef.current || !highlightCanvasRef.current) {
          setLoadingStatus("Missing video/canvas refs ✗");
          console.error(
            "[Mobile Scanner] Missing refs: video=" +
              !!videoRef.current +
              ", canvas=" +
              !!highlightCanvasRef.current,
          );
          return;
        }
        if (!videoRef.current.videoWidth || !videoRef.current.videoHeight) {
          setLoadingStatus("Video has no dimensions ✗");
          console.error(
            "[Mobile Scanner] Missing video dimensions: " +
              videoRef.current.videoWidth +
              "x" +
              videoRef.current.videoHeight,
          );
          return;
        }

        const video = videoRef.current;
        const highlightCanvas = highlightCanvasRef.current;
        setLoadingStatus("Detection active ✓");
        console.log(
          "[Mobile Scanner] Starting highlighting loop for " +
            video.videoWidth +
            "x" +
            video.videoHeight +
            " video",
        );

        // Create low-res detection canvas with optimized context for frequent pixel reading
        const detectionCanvas = document.createElement("canvas");
        const detectionCtx = detectionCanvas.getContext("2d", {
          willReadFrequently: true,
        });
        if (!detectionCtx) return;

        // Calculate scaled dimensions for detection (160px wide max)
        const scale = DETECTION_WIDTH / video.videoWidth;
        detectionCanvas.width = DETECTION_WIDTH;
        detectionCanvas.height = Math.round(video.videoHeight * scale);

        // CRITICAL FIX: Make highlight canvas ALSO low-res (CSS will scale it visually)
        // Drawing to a 4K canvas is what was causing the lag!
        highlightCanvas.width = DETECTION_WIDTH;
        highlightCanvas.height = Math.round(video.videoHeight * scale);

        console.log(
          `[Mobile Scanner] Video: ${video.videoWidth}x${video.videoHeight}`,
        );
        console.log(
          `[Mobile Scanner] Detection: ${detectionCanvas.width}x${detectionCanvas.height} (${Math.round(scale * 100)}%)`,
        );
        console.log(
          `[Mobile Scanner] Highlight canvas: ${highlightCanvas.width}x${highlightCanvas.height}`,
        );
        console.log(`[Mobile Scanner] Starting interval at 1 FPS`);

        // Set highlight canvas to match video for vector drawing
        highlightCanvas.width = video.videoWidth;
        highlightCanvas.height = video.videoHeight;
        const highlightCtx = highlightCanvas.getContext("2d", {
          willReadFrequently: true,
        });
        if (!highlightCtx) return;

        // Use requestAnimationFrame with adaptive throttle based on device performance
        let frameCount = 0;
        const frameTimes: number[] = [];
        let lastDetectionTime = 0;
        let detectionInterval = 333; // Start at 3 FPS (333ms)
        const detectionTimings: number[] = []; // Track last 10 detection times
        const MAX_TIMINGS = 10;

        const runDetection = () => {
          const now = performance.now();

          // Only run detection every second
          if (now - lastDetectionTime >= detectionInterval) {
            lastDetectionTime = now;
            const startTime = performance.now();

            try {
              // Step 1: Copy video to low-res detection canvas
              const copyStart = performance.now();
              detectionCtx.drawImage(
                video,
                0,
                0,
                detectionCanvas.width,
                detectionCanvas.height,
              );
              const copyTime = performance.now() - copyStart;

              // Step 2: Simple jscanify detection
              const detectionStart = performance.now();
              let corners: JscanifyCornerPoints | null = null;

              // Run jscanify detection directly - convert canvas to Mat first
              const cv = window.cv;
              const scanner = scannerRef.current;
              if (cv && scanner) {
                const mat = cv.imread(detectionCanvas);
                const contour = scanner.findPaperContour(mat);
                mat.delete();

                if (contour) {
                  corners = scanner.getCornerPoints(contour);
                }
              }

              const detectionTime = performance.now() - detectionStart;

              // Step 3: Draw corner lines on full-res canvas
              const drawStart = performance.now();
              highlightCtx.clearRect(
                0,
                0,
                highlightCanvas.width,
                highlightCanvas.height,
              );

              // Draw lines if corners detected
              if (
                corners &&
                corners.topLeftCorner &&
                corners.topRightCorner &&
                corners.bottomLeftCorner &&
                corners.bottomRightCorner
              ) {
                // Scale corner points from low-res to full-res
                const scaleFactor = video.videoWidth / detectionCanvas.width;
                const tl = {
                  x: corners.topLeftCorner.x * scaleFactor,
                  y: corners.topLeftCorner.y * scaleFactor,
                };
                const tr = {
                  x: corners.topRightCorner.x * scaleFactor,
                  y: corners.topRightCorner.y * scaleFactor,
                };
                const br = {
                  x: corners.bottomRightCorner.x * scaleFactor,
                  y: corners.bottomRightCorner.y * scaleFactor,
                };
                const bl = {
                  x: corners.bottomLeftCorner.x * scaleFactor,
                  y: corners.bottomLeftCorner.y * scaleFactor,
                };

                // Draw green lines connecting corners
                highlightCtx.strokeStyle = "#00FF00";
                highlightCtx.lineWidth = 4;
                highlightCtx.beginPath();
                highlightCtx.moveTo(tl.x, tl.y);
                highlightCtx.lineTo(tr.x, tr.y);
                highlightCtx.lineTo(br.x, br.y);
                highlightCtx.lineTo(bl.x, bl.y);
                highlightCtx.lineTo(tl.x, tl.y);
                highlightCtx.stroke();
              }

              const drawTime = performance.now() - drawStart;

              const totalTime = performance.now() - startTime;
              frameCount++;
              frameTimes.push(totalTime);

              // Track detection timings for adaptive performance
              detectionTimings.push(totalTime);
              if (detectionTimings.length > MAX_TIMINGS) {
                detectionTimings.shift(); // Keep only last 10
              }

              // Adaptive performance adjustment (after warmup period)
              if (frameCount > 5 && detectionTimings.length >= 5) {
                const avgTime =
                  detectionTimings.reduce((a, b) => a + b, 0) /
                  detectionTimings.length;

                // Adjust detection interval based on average performance
                if (avgTime < 20) {
                  // Very fast device: 5 FPS (200ms)
                  detectionInterval = 200;
                } else if (avgTime < 40) {
                  // Fast device: 3 FPS (333ms)
                  detectionInterval = 333;
                } else if (avgTime < 80) {
                  // Medium device: 2 FPS (500ms)
                  detectionInterval = 500;
                } else {
                  // Slower device: 1 FPS (1000ms)
                  detectionInterval = 1000;
                }
              }

              if (frameCount <= 10) {
                console.log(
                  `[Mobile Scanner] Frame ${frameCount}: ${Math.round(totalTime)}ms total (copy: ${Math.round(copyTime)}ms, detect: ${Math.round(detectionTime)}ms, draw: ${Math.round(drawTime)}ms) - interval: ${detectionInterval}ms`,
                );
              }

              if (frameCount === 10) {
                const avg =
                  frameTimes.reduce((a, b) => a + b, 0) / frameTimes.length;
                console.log(
                  `[Mobile Scanner] Average of first 10 frames: ${Math.round(avg)}ms - Adaptive rate: ${Math.round(1000 / detectionInterval)} FPS`,
                );
              }
            } catch (err) {
              console.error("[Mobile Scanner] Detection error:", err);
            }
          }

          // Continue animation loop
          highlightIntervalRef.current = requestAnimationFrame(runDetection);
        };

        // Start the animation loop
        highlightIntervalRef.current = requestAnimationFrame(runDetection);
      };

      // Wait for video to be ready with retry logic
      let retryCount = 0;
      let retryTimeout: number | null = null;

      const startWhenReady = () => {
        const video = videoRef.current;

        if (!video) {
          setLoadingStatus("No video element ✗");
          console.log("[Mobile Scanner] No video element");
          return;
        }

        console.log(
          `[Mobile Scanner] Video check: readyState=${video.readyState}, width=${video.videoWidth}, height=${video.videoHeight}`,
        );

        if (
          video.readyState >= 2 &&
          video.videoWidth > 0 &&
          video.videoHeight > 0
        ) {
          setLoadingStatus("Detection starting... ✓");
          console.log("[Mobile Scanner] ✓ Video ready, starting detection now");
          startHighlighting();
        } else if (retryCount < 50) {
          // Retry up to 50 times (5 seconds)
          retryCount++;
          setLoadingStatus(`Waiting for video... (${retryCount}/50)`);
          console.log(
            `[Mobile Scanner] Video not ready yet, retry ${retryCount}/50...`,
          );
          retryTimeout = window.setTimeout(startWhenReady, 100);
        } else {
          setLoadingStatus("Video failed to load ✗");
          console.error(
            "[Mobile Scanner] ✗ Video failed to become ready after 5 seconds",
          );
        }
      };

      // Add event listener as fallback
      const videoElement = videoRef.current;
      if (videoElement) {
        console.log("[Mobile Scanner] Adding loadedmetadata listener");
        videoElement.addEventListener("loadedmetadata", startWhenReady);
        // Also try immediately
        startWhenReady();
      } else {
        console.error("[Mobile Scanner] No video element available");
      }

      return () => {
        console.log("[Mobile Scanner] Cleanup: Stopping detection");

        // Clean up animation frame
        if (highlightIntervalRef.current) {
          cancelAnimationFrame(highlightIntervalRef.current);
          highlightIntervalRef.current = null;
        }

        // Clean up retry timeout
        if (retryTimeout !== null) {
          clearTimeout(retryTimeout);
          retryTimeout = null;
        }

        // Clean up event listener
        if (videoElement) {
          videoElement.removeEventListener("loadedmetadata", startWhenReady);
        }
      };
    }
  }, [
    mode,
    autoEnhance,
    openCvReady,
    cameraReady,
    currentPreview,
    adjustState,
  ]);

  const captureImage = useCallback(async () => {
    if (!videoRef.current || !canvasRef.current) return;

    setIsProcessing(true);

    try {
      const video = videoRef.current;
      const canvas = canvasRef.current;
      const context = canvas.getContext("2d");

      if (!context) return;

      // Capture raw image from video at full resolution
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
      context.drawImage(video, 0, 0, canvas.width, canvas.height);

      const cv = window.cv;
      const scanner = scannerRef.current;

      if (!autoEnhance || !scanner || !openCvReady || !cv) {
        // Auto-enhance disabled or jscanify not available - use original at high quality,
        // skip the corner-adjust step entirely (user explicitly turned off edge detection).
        setPreviewBase(canvas.toDataURL("image/jpeg", 0.95));
        return;
      }

      // Best-effort automatic detection; falls back to an inset rectangle the
      // user can drag into place on the adjust screen if this fails.
      let corners: JscanifyCornerPoints = defaultCorners(
        canvas.width,
        canvas.height,
      );

      try {
        // Higher-res than the live preview overlay: this runs once per photo
        // (not per frame), so we can afford much more detail for a better contour.
        const detectionCanvas = document.createElement("canvas");
        const detectionCtx = detectionCanvas.getContext("2d", {
          willReadFrequently: true,
        });
        if (!detectionCtx) throw new Error("Cannot create detection context");

        const scale = CAPTURE_DETECTION_WIDTH / video.videoWidth;
        detectionCanvas.width = CAPTURE_DETECTION_WIDTH;
        detectionCanvas.height = Math.round(video.videoHeight * scale);
        detectionCtx.drawImage(
          video,
          0,
          0,
          detectionCanvas.width,
          detectionCanvas.height,
        );

        const mat = cv.imread(detectionCanvas);
        const contour = scanner.findPaperContour(mat);
        mat.delete();

        if (contour) {
          const cornerPoints = scanner.getCornerPoints(contour);
          if (
            cornerPoints?.topLeftCorner &&
            cornerPoints.topRightCorner &&
            cornerPoints.bottomLeftCorner &&
            cornerPoints.bottomRightCorner
          ) {
            const scaleFactor = 1 / scale;
            corners = {
              topLeftCorner: {
                x: cornerPoints.topLeftCorner.x * scaleFactor,
                y: cornerPoints.topLeftCorner.y * scaleFactor,
              },
              topRightCorner: {
                x: cornerPoints.topRightCorner.x * scaleFactor,
                y: cornerPoints.topRightCorner.y * scaleFactor,
              },
              bottomLeftCorner: {
                x: cornerPoints.bottomLeftCorner.x * scaleFactor,
                y: cornerPoints.bottomLeftCorner.y * scaleFactor,
              },
              bottomRightCorner: {
                x: cornerPoints.bottomRightCorner.x * scaleFactor,
                y: cornerPoints.bottomRightCorner.y * scaleFactor,
              },
            };
          }
        }
      } catch (err) {
        console.warn(
          "[Mobile Scanner] Detection failed, using default corners:",
          err,
        );
      }

      setAdjustState({
        dataUrl: canvas.toDataURL("image/jpeg", 0.95),
        width: canvas.width,
        height: canvas.height,
        corners,
      });
    } finally {
      setIsProcessing(false);
    }
  }, [autoEnhance, openCvReady]);

  const confirmAdjustedCorners = useCallback(
    async (finalCorners: JscanifyCornerPoints) => {
      if (!adjustState) return;
      const scanner = scannerRef.current;

      if (!scanner || !window.cv) {
        setPreviewBase(adjustState.dataUrl);
        setAdjustState(null);
        return;
      }

      setIsProcessing(true);
      try {
        const img = new Image();
        await new Promise<void>((resolve, reject) => {
          img.onload = () => resolve();
          img.onerror = () =>
            reject(new Error("Failed to load captured image"));
          img.src = adjustState.dataUrl;
        });

        const sourceCanvas = document.createElement("canvas");
        sourceCanvas.width = adjustState.width;
        sourceCanvas.height = adjustState.height;
        const ctx = sourceCanvas.getContext("2d");
        if (!ctx) throw new Error("Cannot create canvas context");
        ctx.drawImage(img, 0, 0);

        const {
          topLeftCorner,
          topRightCorner,
          bottomLeftCorner,
          bottomRightCorner,
        } = finalCorners;
        const topWidth = Math.hypot(
          topRightCorner.x - topLeftCorner.x,
          topRightCorner.y - topLeftCorner.y,
        );
        const bottomWidth = Math.hypot(
          bottomRightCorner.x - bottomLeftCorner.x,
          bottomRightCorner.y - bottomLeftCorner.y,
        );
        const leftHeight = Math.hypot(
          bottomLeftCorner.x - topLeftCorner.x,
          bottomLeftCorner.y - topLeftCorner.y,
        );
        const rightHeight = Math.hypot(
          bottomRightCorner.x - topRightCorner.x,
          bottomRightCorner.y - topRightCorner.y,
        );
        const docWidth = Math.round((topWidth + bottomWidth) / 2);
        const docHeight = Math.round((leftHeight + rightHeight) / 2);

        const resultCanvas = scanner.extractPaper(
          sourceCanvas,
          docWidth,
          docHeight,
          finalCorners,
        );
        setPreviewBase(resultCanvas.toDataURL("image/jpeg", 0.95));
      } catch (err) {
        console.warn(
          "[Mobile Scanner] extractPaper failed, using raw capture:",
          err,
        );
        setPreviewBase(adjustState.dataUrl);
      } finally {
        setAdjustState(null);
        setIsProcessing(false);
      }
    },
    [adjustState],
  );

  const cancelAdjust = useCallback(() => {
    setAdjustState(null);
  }, []);

  /**
   * Run a filter over a base data URL and return a filtered data URL. Passing
   * `targetWidth` produces a low-res thumbnail; omit it for the full-res output
   * used when the image is added to the batch or uploaded.
   */
  const applyFilter = useCallback(
    async (
      baseDataUrl: string,
      filter: EnhanceFilter,
      adjustments: EnhanceAdjustments,
      targetWidth?: number,
    ): Promise<string> => {
      const image = await loadImage(baseDataUrl);
      const canvas = imageToCanvas(image);
      const source = canvasToImageData(canvas, targetWidth);
      const enhanced = enhanceImageData(source, filter, adjustments);
      return imageDataToDataUrl(enhanced, filter);
    },
    [],
  );

  // Reset filter selection whenever a fresh capture arrives.
  useEffect(() => {
    if (previewBase) {
      setActiveFilter("magicColor");
      setBrightness(0);
      setContrast(1);
    }
  }, [previewBase]);

  // Build the low-res filter thumbnails once per capture.
  useEffect(() => {
    if (!previewBase || !openCvReady) {
      setFilterThumbs({});
      return;
    }
    let cancelled = false;
    (async () => {
      const thumbs: Partial<Record<EnhanceFilter, string>> = {};
      for (const filter of FILTER_ORDER) {
        try {
          thumbs[filter] = await applyFilter(
            previewBase,
            filter,
            {},
            THUMB_WIDTH,
          );
        } catch (err) {
          console.warn(`[Mobile Scanner] Thumbnail failed for ${filter}:`, err);
        }
        if (cancelled) return;
      }
      if (!cancelled) setFilterThumbs(thumbs);
    })();
    return () => {
      cancelled = true;
    };
  }, [previewBase, openCvReady, applyFilter]);

  // Derive the displayed preview from base + active filter + adjustments.
  useEffect(() => {
    if (!previewBase) return;
    const adjustments: EnhanceAdjustments = { brightness, contrast };
    const isPlainOriginal =
      activeFilter === "original" && brightness === 0 && contrast === 1;
    if (isPlainOriginal || !openCvReady) {
      setCurrentPreview(previewBase);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const filtered = await applyFilter(
          previewBase,
          activeFilter,
          adjustments,
          PREVIEW_WIDTH,
        );
        if (!cancelled) setCurrentPreview(filtered);
      } catch (err) {
        console.warn("[Mobile Scanner] Filter preview failed:", err);
        if (!cancelled) setCurrentPreview(previewBase);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [
    previewBase,
    activeFilter,
    brightness,
    contrast,
    openCvReady,
    applyFilter,
  ]);

  const handleFileSelect = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const files = e.target.files;
      if (!files || files.length === 0) return;

      const file = files[0];
      const reader = new FileReader();

      reader.onload = (event) => {
        if (event.target?.result) {
          setPreviewBase(event.target.result as string);
        }
      };

      reader.readAsDataURL(file);
    },
    [],
  );

  // Render the current capture at full resolution with the selected filter.
  const renderFinalImage = useCallback(async (): Promise<string | null> => {
    if (!previewBase) return null;
    if (!openCvReady) return previewBase;
    const adjustments: EnhanceAdjustments = { brightness, contrast };
    if (activeFilter === "original" && brightness === 0 && contrast === 1) {
      return previewBase;
    }
    try {
      return await applyFilter(previewBase, activeFilter, adjustments);
    } catch (err) {
      console.warn("[Mobile Scanner] Full-res filter failed:", err);
      return previewBase;
    }
  }, [
    previewBase,
    openCvReady,
    activeFilter,
    brightness,
    contrast,
    applyFilter,
  ]);

  const addToBatch = useCallback(async () => {
    const finalImage = await renderFinalImage();
    if (finalImage) {
      setCapturedImages((prev) => [...prev, finalImage]);
      setPreviewBase(null);
      setCurrentPreview(null);
    }
  }, [renderFinalImage]);

  const uploadImages = useCallback(async () => {
    const finalImage = await renderFinalImage();
    const imagesToUpload = finalImage
      ? [finalImage, ...capturedImages]
      : capturedImages;

    if (imagesToUpload.length === 0) return;
    if (!sessionId) return;

    setIsUploading(true);
    setUploadError(null);
    setUploadProgress(0);

    try {
      // Convert data URLs to File objects
      const files: File[] = [];
      for (let i = 0; i < imagesToUpload.length; i++) {
        const dataUrl = imagesToUpload[i];
        const response = await fetch(dataUrl);
        const blob = await response.blob();
        const isPng = dataUrl.startsWith("data:image/png");
        const file = new File(
          [blob],
          `scan-${Date.now()}-${i}.${isPng ? "png" : "jpg"}`,
          { type: isPng ? "image/png" : "image/jpeg" },
        );
        files.push(file);
        setUploadProgress(((i + 1) / (imagesToUpload.length + 1)) * 50); // 0-50% for conversion
      }

      // Upload to backend
      const formData = new FormData();
      files.forEach((file) => {
        formData.append("files", file);
      });

      const uploadResponse = await fetch(
        `${API_BASE}/api/v1/mobile-scanner/upload/${sessionId}`,
        {
          method: "POST",
          body: formData,
        },
      );

      if (!uploadResponse.ok) {
        throw new Error("Upload failed");
      }

      setUploadProgress(100);
      setUploadSuccess(true);

      // Close the mobile tab after successful upload
      setTimeout(() => {
        window.close();
        // Fallback if window.close() doesn't work (some browsers block it)
        if (!window.closed) {
          navigate("/");
        }
      }, 1500);
    } catch (err) {
      console.error("Upload failed:", err);
      setUploadError(
        t("mobileScanner.uploadFailed", "Upload failed. Please try again."),
      );
    } finally {
      setIsUploading(false);
    }
  }, [renderFinalImage, capturedImages, sessionId, navigate, t]);

  const retake = useCallback(() => {
    setPreviewBase(null);
    setCurrentPreview(null);
  }, []);

  const clearBatch = useCallback(() => {
    setCapturedImages([]);
  }, []);

  const toggleTorch = useCallback(async () => {
    if (!streamRef.current) return;

    try {
      const videoTrack = streamRef.current.getVideoTracks()[0];
      await videoTrack.applyConstraints({
        advanced: [{ torch: !torchEnabled }],
      });
      setTorchEnabled(!torchEnabled);
      console.log("Torch:", !torchEnabled ? "ON" : "OFF");
    } catch (err) {
      console.error("Failed to toggle torch:", err);
    }
  }, [torchEnabled]);

  // Show loading while validating
  if (sessionValid === null) {
    return (
      <Box
        p="xl"
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          gap: "1rem",
        }}
      >
        <Text size="lg">
          {t("mobileScanner.validating", "Validating session...")}
        </Text>
      </Box>
    );
  }

  // Show error if session is invalid
  if (!sessionValid || !sessionId) {
    return (
      <Box p="xl">
        <Alert
          color="red"
          title={t("mobileScanner.sessionInvalid", "Session Error")}
        >
          {sessionError ||
            t(
              "mobileScanner.noSessionMessage",
              "Session not found. Please try again.",
            )}
        </Alert>
      </Box>
    );
  }

  if (uploadSuccess) {
    return (
      <Box
        style={{
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          height: "100dvh",
          padding: "2rem",
        }}
      >
        <CheckCircleRoundedIcon
          style={{ fontSize: "4rem", color: "var(--mantine-color-green-6)" }}
        />
        <Text size="xl" fw="bold" mt="md">
          {t("mobileScanner.uploadSuccess", "Upload Successful!")}
        </Text>
        <Text size="sm" c="dimmed">
          {t(
            "mobileScanner.uploadSuccessMessage",
            "Your images have been transferred.",
          )}
        </Text>
      </Box>
    );
  }

  return (
    <Box
      style={{
        minHeight: "100dvh",
        background: "var(--bg-background)",
        display: "flex",
        flexDirection: "column",
      }}
    >
      {adjustState && (
        <CornerAdjustScreen
          dataUrl={adjustState.dataUrl}
          naturalWidth={adjustState.width}
          naturalHeight={adjustState.height}
          initialCorners={adjustState.corners}
          processing={isProcessing}
          onConfirm={confirmAdjustedCorners}
          onCancel={cancelAdjust}
        />
      )}

      {/* Header */}
      <Box
        p="md"
        style={{
          background: "var(--bg-toolbar)",
          borderBottom: "1px solid var(--border-subtle)",
        }}
      >
        <Group gap="sm" align="center">
          <LogoIcon
            alt={t("home.mobile.brandAlt", "Stirling PDF logo")}
            style={{ height: "32px", width: "32px" }}
          />
          <Wordmark alt="Stirling PDF" style={{ height: "24px" }} />
        </Group>
      </Box>

      {/* Status Banner - only show during camera loading or errors */}
      {loadingStatus && mode === "camera" && !loadingStatus.includes("✓") && (
        <Box
          p="xs"
          style={{
            background: loadingStatus.includes("✗")
              ? "var(--mantine-color-red-1)"
              : "var(--mantine-color-blue-1)",
            borderBottom: "1px solid var(--border-subtle)",
            fontSize: "0.85rem",
            fontFamily: "monospace",
            textAlign: "center",
          }}
        >
          {loadingStatus}
        </Box>
      )}

      {uploadError && (
        <Box p="md">
          <Alert
            color="red"
            icon={<ErrorRoundedIcon />}
            onClose={() => setUploadError(null)}
            withCloseButton
          >
            {uploadError}
          </Alert>
        </Box>
      )}

      {isUploading && (
        <Box p="sm">
          <Text size="sm" mb="xs">
            {t("mobileScanner.uploading", "Uploading...")}
          </Text>
          <Progress value={uploadProgress} animated />
        </Box>
      )}

      {cameraError && (
        <Box p="md">
          <Alert color="orange" icon={<InfoRoundedIcon />}>
            {cameraError}
          </Alert>
        </Box>
      )}

      {/* Choice screen */}
      {mode === "choice" && !currentPreview && (
        <Stack
          gap="lg"
          p="xl"
          align="center"
          style={{ maxWidth: "500px", margin: "0 auto" }}
        >
          <Stack gap="xs" align="center">
            <Text size="xl" fw={700} ta="center">
              {t("mobileScanner.chooseMethod", "Choose Upload Method")}
            </Text>
            <Text size="sm" c="dimmed" ta="center">
              {t(
                "mobileScanner.chooseMethodDescription",
                "Select how you want to scan and upload documents",
              )}
            </Text>
          </Stack>

          <Stack gap="md" style={{ width: "100%" }}>
            <Card
              shadow="sm"
              padding="xl"
              radius="md"
              withBorder
              style={{ cursor: "pointer" }}
              onClick={() => setMode("camera")}
              styles={{
                root: {
                  transition: "transform 0.2s, box-shadow 0.2s",
                  "&:hover": {
                    transform: "scale(1.02)",
                    boxShadow: "var(--mantine-shadow-md)",
                  },
                },
              }}
            >
              <Stack align="center" gap="md">
                <PhotoCameraRoundedIcon
                  style={{
                    fontSize: "3rem",
                    color: "var(--mantine-color-blue-6)",
                  }}
                />
                <Text size="lg" fw={600}>
                  {t("mobileScanner.camera", "Camera")}
                </Text>
                <Text size="sm" c="dimmed" ta="center">
                  {t(
                    "mobileScanner.cameraDescription",
                    "Scan documents using your device camera with automatic edge detection",
                  )}
                </Text>
              </Stack>
            </Card>

            <Card
              shadow="sm"
              padding="xl"
              radius="md"
              withBorder
              style={{ cursor: "pointer" }}
              onClick={() => setMode("file")}
              styles={{
                root: {
                  transition: "transform 0.2s, box-shadow 0.2s",
                  "&:hover": {
                    transform: "scale(1.02)",
                    boxShadow: "var(--mantine-shadow-md)",
                  },
                },
              }}
            >
              <Stack align="center" gap="md">
                <UploadRoundedIcon
                  style={{
                    fontSize: "3rem",
                    color: "var(--mantine-color-green-6)",
                  }}
                />
                <Text size="lg" fw={600}>
                  {t("mobileScanner.fileUpload", "File Upload")}
                </Text>
                <Text size="sm" c="dimmed" ta="center">
                  {t(
                    "mobileScanner.fileDescription",
                    "Upload existing photos or documents from your device",
                  )}
                </Text>
              </Stack>
            </Card>
          </Stack>
        </Stack>
      )}

      {/* Camera interface */}
      {mode === "camera" && !currentPreview && (
        <Box
          style={{
            position: "relative",
            height: "calc(100dvh - 60px)",
            display: "flex",
            flexDirection: "column",
          }}
        >
          {/* Back button - floating top left */}
          <Button
            onClick={() => setMode("choice")}
            variant="filled"
            size="sm"
            style={{
              position: "absolute",
              top: "1rem",
              left: "1rem",
              zIndex: 10,
              backgroundColor: "rgba(0, 0, 0, 0.6)",
              backdropFilter: "blur(8px)",
              border: "none",
            }}
          >
            ← {t("mobileScanner.back", "Back")}
          </Button>

          {/* Video feed - fills available space */}
          <Box
            style={{
              position: "relative",
              flex: 1,
              background: "#000",
              overflow: "hidden",
            }}
          >
            <video
              ref={videoRef}
              autoPlay
              playsInline
              muted
              style={{
                width: "100%",
                height: "100%",
                display: "block",
                objectFit: "contain",
              }}
            />
            <canvas ref={canvasRef} style={{ display: "none" }} />
            {/* Highlight overlay canvas - shows real-time document edge detection */}
            <canvas
              ref={highlightCanvasRef}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                width: "100%",
                height: "100%",
                pointerEvents: "none",
                opacity: autoEnhance ? 1 : 0,
                transition: "opacity 0.2s",
                objectFit: "contain",
                imageRendering: "auto",
              }}
            />
          </Box>

          {/* Controls bar - fixed at bottom */}
          <Box
            style={{
              backgroundColor: "var(--bg-toolbar)",
              borderTop: "1px solid var(--border-subtle)",
              padding: "0.75rem 1rem",
            }}
          >
            <Stack gap="sm">
              {/* Settings toggles */}
              <Group justify="space-around" style={{ width: "100%" }}>
                <Group gap="xs">
                  <Switch
                    size="sm"
                    checked={autoEnhance}
                    onChange={(e) => setAutoEnhance(e.currentTarget.checked)}
                    disabled={!openCvReady}
                  />
                  <Text size="xs">
                    {t("mobileScanner.edgeDetection", "Edge Detection")}
                  </Text>
                </Group>
                {torchSupported && (
                  <Group gap="xs">
                    <Switch
                      size="sm"
                      checked={torchEnabled}
                      onChange={toggleTorch}
                    />
                    <Text size="xs">
                      {t("mobileScanner.flashlight", "Flash")}
                    </Text>
                  </Group>
                )}
              </Group>

              {/* Capture button */}
              <Button
                fullWidth
                size="lg"
                onClick={captureImage}
                loading={isProcessing}
                variant="filled"
                radius="xl"
              >
                {isProcessing
                  ? t("mobileScanner.processing", "Processing...")
                  : t("mobileScanner.capture", "Capture")}
              </Button>
            </Stack>
          </Box>
        </Box>
      )}

      {/* File upload interface */}
      {mode === "file" && !currentPreview && (
        <Stack
          gap="lg"
          p="xl"
          align="center"
          style={{ maxWidth: "500px", margin: "0 auto" }}
        >
          <Button
            onClick={() => setMode("choice")}
            variant="subtle"
            size="sm"
            style={{ alignSelf: "flex-start" }}
          >
            ← {t("mobileScanner.back", "Back")}
          </Button>

          <Card
            shadow="sm"
            padding="xl"
            radius="md"
            withBorder
            style={{ width: "100%" }}
          >
            <Stack align="center" gap="lg">
              <UploadRoundedIcon
                style={{
                  fontSize: "4rem",
                  color: "var(--mantine-color-gray-5)",
                }}
              />
              <Text size="lg" fw={600} ta="center">
                {t("mobileScanner.selectFilesPrompt", "Select files to upload")}
              </Text>
              <input
                ref={fileInputRef}
                type="file"
                accept="image/*"
                multiple
                style={{ display: "none" }}
                onChange={handleFileSelect}
              />
              <Button
                size="lg"
                variant="filled"
                fullWidth
                onClick={() => fileInputRef.current?.click()}
                leftSection={<AddPhotoAlternateRoundedIcon />}
              >
                {t("mobileScanner.selectImage", "Select Image")}
              </Button>
            </Stack>
          </Card>
        </Stack>
      )}

      {/* Preview interface */}
      {currentPreview && (
        <Box
          style={{
            position: "relative",
            height: "calc(100dvh - 60px)",
            display: "flex",
            flexDirection: "column",
          }}
        >
          {/* Preview image - fills available space */}
          <Box
            style={{
              position: "relative",
              flex: 1,
              background: "#000",
              overflow: "hidden",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <img
              src={currentPreview}
              alt="Preview"
              style={{
                maxWidth: "100%",
                maxHeight: "100%",
                display: "block",
                objectFit: "contain",
              }}
            />
          </Box>

          {/* Controls bar - fixed at bottom */}
          <Box
            style={{
              backgroundColor: "var(--bg-toolbar)",
              borderTop: "1px solid var(--border-subtle)",
              padding: "0.75rem 1rem",
            }}
          >
            <Stack gap="sm">
              {previewBase && openCvReady && (
                <>
                  <Box
                    style={{
                      display: "flex",
                      gap: "var(--space-sm)",
                      overflowX: "auto",
                      paddingBottom: "var(--space-xs)",
                    }}
                  >
                    {FILTER_ORDER.map((filter) => (
                      <Stack
                        key={filter}
                        gap={4}
                        align="center"
                        style={{ cursor: "pointer", flexShrink: 0 }}
                        onClick={() => setActiveFilter(filter)}
                      >
                        <Box
                          style={{
                            width: "56px",
                            height: "56px",
                            borderRadius: "var(--radius-sm)",
                            overflow: "hidden",
                            border:
                              activeFilter === filter
                                ? "2px solid var(--mantine-color-blue-6)"
                                : "2px solid var(--border-subtle)",
                            background: "var(--bg-background)",
                          }}
                        >
                          {filterThumbs[filter] && (
                            <img
                              src={filterThumbs[filter]}
                              alt={filter}
                              style={{
                                width: "100%",
                                height: "100%",
                                objectFit: "cover",
                              }}
                            />
                          )}
                        </Box>
                        <Text size="xs">
                          {t(
                            `mobileScanner.filter${filter.charAt(0).toUpperCase() + filter.slice(1)}`,
                            filter,
                          )}
                        </Text>
                      </Stack>
                    ))}
                  </Box>
                  <Box>
                    <Text size="xs" c="dimmed">
                      {t("mobileScanner.brightness", "Brightness")}
                    </Text>
                    <Slider
                      value={brightness}
                      onChange={setBrightness}
                      min={-100}
                      max={100}
                      step={5}
                      label={null}
                    />
                  </Box>
                  <Box>
                    <Text size="xs" c="dimmed">
                      {t("mobileScanner.contrast", "Contrast")}
                    </Text>
                    <Slider
                      value={contrast}
                      onChange={setContrast}
                      min={0.5}
                      max={2}
                      step={0.05}
                      label={null}
                    />
                  </Box>
                </>
              )}
              <Group grow>
                <Button variant="default" onClick={retake} size="lg">
                  {t("mobileScanner.retake", "Retake")}
                </Button>
                <Button variant="filled" onClick={addToBatch} size="lg">
                  {t("mobileScanner.addToBatch", "Add to Batch")}
                </Button>
              </Group>
              <Button
                fullWidth
                variant="filled"
                size="lg"
                onClick={uploadImages}
                loading={isUploading}
                radius="xl"
              >
                {t("mobileScanner.upload", "Upload")}
              </Button>
            </Stack>
          </Box>
        </Box>
      )}

      {capturedImages.length > 0 && (
        <Box p="sm" style={{ borderTop: "1px solid var(--border-subtle)" }}>
          <Group justify="space-between" mb="sm">
            <Text size="sm" fw={600}>
              {t("mobileScanner.batchImages", "Batch")} ({capturedImages.length}
              )
            </Text>
            <Group gap="xs">
              <Button
                size="xs"
                variant="outline"
                onClick={clearBatch}
                color="red"
              >
                {t("mobileScanner.clearBatch", "Clear")}
              </Button>
              <Button size="xs" onClick={uploadImages} loading={isUploading}>
                {t("mobileScanner.uploadAll", "Upload All")}
              </Button>
            </Group>
          </Group>
          <Box
            style={{
              display: "flex",
              gap: "var(--space-sm)",
              overflowX: "auto",
              paddingBottom: "var(--space-sm)",
            }}
          >
            {capturedImages.map((img, idx) => (
              <Box
                key={idx}
                style={{
                  minWidth: "80px",
                  height: "80px",
                  borderRadius: "var(--radius-sm)",
                  overflow: "hidden",
                  border: "2px solid var(--border-subtle)",
                }}
              >
                <img
                  src={img}
                  alt={`Capture ${idx + 1}`}
                  style={{ width: "100%", height: "100%", objectFit: "cover" }}
                />
              </Box>
            ))}
          </Box>
        </Box>
      )}
    </Box>
  );
}
