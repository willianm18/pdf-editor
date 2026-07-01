# PRD — Scanner Mobile "tipo CamScanner"

> Objetivo do produto: substituir o Adobe / ferramentas online por um editor de PDF
> próprio, com um scanner mobile de **alta qualidade**. Foco em uso pessoal, mas com
> nível de acabamento comparável ao CamScanner.

## Contexto e decisões travadas

- **Onde roda:** 100% no navegador do celular. O scanner é aberto via QR code a
  partir do desktop; o backend (`MobileScannerService.java`) é apenas um "correio"
  (guarda o arquivo por ~10 min e repassa ao desktop). **Nenhum** processamento de
  imagem no servidor — e assim permanece.
- **Stack de imagem:** `jscanify` + OpenCV.js (WASM), dentro de
  `frontend/editor/src/core/pages/MobileScannerPage.tsx` e
  `frontend/editor/src/core/utils/loadJscanify.ts`.
- **Aparelho alvo:** Android / Chrome (torch, foco/exposição e `ImageCapture`
  disponíveis; `onnxruntime-web` viável se a Fase 4 exigir ML).
- **Sequência recomendada:** 1 → 2 → 3; entrar na 4 só se a detecção ainda incomodar.

## Diagnóstico do estado atual (por que dói)

| Sintoma relatado | Causa raiz no código |
|---|---|
| "Não detecta bem as bordas" | Detecção clássica do jscanify (maior contorno de 4 lados); preview em tempo real a `DETECTION_WIDTH = 160px`. Quebra em fundo bagunçado / baixo contraste. Sem ML. |
| "Demora um pouco" | Cold start do OpenCV.js WASM (até ~15s no 1º load); loop de detecção a 3 FPS; na captura re-detecta a 800px + warp em resolução cheia. |
| "Qualidade precisa melhorar" | **Não existe etapa de melhoria de imagem.** `extractPaper` só recorta a perspectiva e salva JPEG 0.95. Sem binarização, tons de cinza, magic color, contraste ou remoção de sombra. |

**Insight central:** o maior ganho de qualidade percebida **não** é a detecção de
borda — é a etapa de melhoria (enhancement) que hoje simplesmente não existe.

## Mapa de capacidades vs. CamScanner

| Capacidade | Hoje | CamScanner | Fase |
|---|---|---|---|
| Detecção de borda em tempo real | Fraca (clássica, 160px) | Robusta (ML) | 4 |
| Auto-captura (estável + enquadrado) | ❌ | ✅ | 3 |
| Correção de perspectiva | ✅ (ok) | ✅ | — |
| Filtros de melhoria (Magic/Cinza/P&B) | ❌ | ✅ | **1** |
| Remoção de sombra | ❌ | ✅ | **1** |
| Ajuste manual de cantos com lupa | Parcial (sem lupa) | ✅ | 2 |
| Lote multi-página | ✅ (básico) | ✅ | — |

---

## Fase 1 — Pipeline de melhoria de imagem 🎯 *(maior ROI)*

Transforma "foto recortada" em "documento escaneado". Tudo em OpenCV.js, sobre o
canvas capturado em resolução cheia.

**Escopo**
- Novo módulo `frontend/editor/src/core/utils/imageEnhance.ts` com funções puras:
  - **Magic Color** (padrão): white-balance grayworld + auto-contraste (percentis do
    histograma) + leve saturação em HSV.
  - **Tons de cinza**: `cvtColor(GRAY)` + auto-contraste.
  - **P&B / Documento**: remoção de sombra → `adaptiveThreshold` (Gaussiano,
    blockSize ~15, C ~10).
  - **Original**: passthrough.
  - **Remoção de sombra** (helper): fundo por `morphologyEx(MORPH_CLOSE)` kernel
    grande → `divide(img, bg, scale=255)`.
  - Ajuste de brilho/contraste (sliders).
- UI: tira horizontal de miniaturas na tela de preview; miniaturas em ~120px
  (instantâneas), filtro em resolução cheia só na confirmação.
- Saída inteligente: P&B → PNG; cor/cinza → JPEG 0.92 (corrige texto borrado do
  JPEG 0.95 atual).

**Critérios de aceite**
- Troca de filtro atualiza o preview em <300ms (miniatura); aplica em res cheia ao
  confirmar.
- P&B legível em documento com sombra lateral.
- Fluxo de lote/upload atual intacto.
- Sem vazamento de `Mat` do OpenCV.

**Esforço:** baixo-médio · **Impacto:** altíssimo · **Dependências novas:** nenhuma.

---

## Fase 2 — Ajuste de cantos com lupa e sempre disponível

**Escopo**
- **Lupa (magnifier loupe)** ao arrastar um canto: círculo com zoom dos pixels sob o
  dedo (o dedo tapa o ponto exato no mobile). A tela `CornerAdjustScreen` já existe;
  falta a lupa.
- **Corrigir inconsistência**: hoje, se a detecção de borda está desligada ou não
  achou nada, o fluxo **pula** o ajuste de cantos. O ajuste manual deve estar sempre
  disponível.
- Opcional: assistência de "snap" pra borda mais próxima.

**Critérios de aceite**
- Ao arrastar um canto, a lupa mostra o zoom da região sob o dedo.
- O ajuste manual é acessível independentemente do estado da detecção automática.

**Esforço:** baixo · **Impacto:** médio-alto (é o "caso seja necessário").

---

## Fase 3 — Velocidade + auto-captura

**Escopo**
- **Matar o cold start**: pré-carregar o OpenCV.js na tela de escolha (ou quando o QR
  é gerado), pra WASM estar pronto antes de apontar a câmera.
- **Detecção em Web Worker** (OffscreenCanvas): tira o processamento da thread do
  vídeo; permite subir bem acima de 3 FPS sem travar a imagem.
- **Auto-captura**: cantos estáveis por N frames + preenchimento suficiente do quadro
  + foco ok → dispara automaticamente com anel de contagem. Botão manual como
  fallback.
- **Captura mais rápida**: reaproveitar os últimos cantos detectados ao vivo em vez de
  re-detectar a 800px.

**Critérios de aceite**
- Tempo perceptível até a câmera "pronta" reduzido (sem espera de WASM visível).
- Vídeo fluido durante a detecção.
- Auto-captura dispara de forma confiável e pode ser desativada.

**Esforço:** médio · **Impacto:** alto na fluidez.

---

## Fase 4 — Detecção de borda robusta *(só se 1–3 não bastarem)*

**Escopo**
- **Primeiro, afinar o CV clássico** (barato): filtro bilateral, Canny com thresholds
  automáticos, pontuar contornos por área + convexidade + proporção, e **rejeitar com
  baixa confiança** em vez de chutar.
- **Se ainda faltar**: modelo pequeno de segmentação/cantos de documento via
  `onnxruntime-web` (WASM/WebGL; roda no Android; ~poucos MB). Nível CamScanner de
  robustez em fundo difícil.

**Critérios de aceite**
- Detecção estável em fundo de baixo contraste e texturizado.
- Sem falso-positivo grosseiro (prefere não detectar a detectar errado).

**Esforço:** médio (CV) a alto (ML) · **Impacto:** alto na robustez.

---

## Métricas de sucesso (uso pessoal)

- Tempo do "abrir câmera" até "documento no lote" ≤ ~5s.
- Taxa de re-captura (retake) baixa — a primeira captura costuma servir.
- Legibilidade do P&B em documentos com sombra.
- Zero regressão no fluxo de lote/upload existente.

## Fora de escopo (por ora)

- Processamento de imagem no servidor.
- OCR / texto pesquisável (candidato a fase futura, pode usar o pipeline existente do
  Stirling-PDF no desktop).
- App nativo (mantém-se web via QR code).
