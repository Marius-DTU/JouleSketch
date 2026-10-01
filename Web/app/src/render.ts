// Paints the primitives made by SchematicScene.swift (encoded by SceneJSON
// in Web/Bridge/JSONWriter.swift). All drawing decisions are made in Swift;
// this only turns the primitives into canvas calls.

type Color = [number, number, number, number];

interface TextRun {
  s: string;
  z: number;
  w: number;
  i?: boolean;
  o?: number;
  c: Color;
}

type Primitive =
  | { t: "s"; p: number[]; c: Color; w: number; d?: number[]; b?: boolean }
  | { t: "f"; p: number[]; c: Color; e?: boolean }
  | { t: "x"; x: number; y: number; ax: number; ay: number; r: TextRun[] }
  | { t: "d"; p: number[]; z: number; c: Color };

const FONT_FAMILY = `-apple-system, "SF Pro Text", "Segoe UI", system-ui, sans-serif`;

function css([r, g, b, a]: Color): string {
  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a})`;
}

function font(run: TextRun): string {
  return `${run.i ? "italic " : ""}${run.w} ${run.z}px ${FONT_FAMILY}`;
}

/** Adds the path operations (see SceneJSON) to the context's current path. */
function trace(ctx: CanvasRenderingContext2D, p: number[]) {
  ctx.beginPath();
  let i = 0;
  while (i < p.length) {
    switch (p[i]) {
      case 0:
        ctx.moveTo(p[i + 1], p[i + 2]);
        i += 3;
        break;
      case 1:
        ctx.lineTo(p[i + 1], p[i + 2]);
        i += 3;
        break;
      case 2:
        ctx.closePath();
        i += 1;
        break;
      case 3: {
        const [x, y, w, h] = [p[i + 1], p[i + 2], p[i + 3], p[i + 4]];
        ctx.moveTo(x + w, y + h / 2);
        ctx.ellipse(x + w / 2, y + h / 2, Math.abs(w / 2), Math.abs(h / 2), 0, 0, Math.PI * 2);
        ctx.closePath();
        i += 5;
        break;
      }
      case 4:
        ctx.rect(p[i + 1], p[i + 2], p[i + 3], p[i + 4]);
        i += 5;
        break;
      case 5:
        ctx.roundRect(p[i + 1], p[i + 2], p[i + 3], p[i + 4], p[i + 5]);
        i += 6;
        break;
      default:
        return;
    }
  }
}

function drawText(ctx: CanvasRenderingContext2D, prim: Extract<Primitive, { t: "x" }>) {
  // Measure the runs to place the whole label by its anchor, like SwiftUI does.
  let width = 0;
  let size = 0;
  const widths = prim.r.map((run) => {
    ctx.font = font(run);
    const w = ctx.measureText(run.s).width;
    width += w;
    if (!run.o) size = Math.max(size, run.z);
    return w;
  });
  if (size === 0) size = Math.max(...prim.r.map((r) => r.z));
  const ascent = size * 0.95;
  const height = size * 1.2;
  let x = prim.x - prim.ax * width;
  const baseline = prim.y - prim.ay * height + ascent;
  ctx.textBaseline = "alphabetic";
  prim.r.forEach((run, index) => {
    ctx.font = font(run);
    ctx.fillStyle = css(run.c);
    ctx.fillText(run.s, x, baseline - (run.o ?? 0));
    x += widths[index];
  });
}

export function paint(ctx: CanvasRenderingContext2D, sceneJSON: string, background: string, width: number, height: number) {
  const primitives = JSON.parse(sceneJSON) as Primitive[];
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, width, height);
  ctx.lineJoin = "round";
  for (const prim of primitives) {
    switch (prim.t) {
      case "s":
        trace(ctx, prim.p);
        ctx.strokeStyle = css(prim.c);
        ctx.lineWidth = prim.w;
        ctx.lineCap = prim.b ? "butt" : "round";
        ctx.setLineDash(prim.d ?? []);
        ctx.stroke();
        ctx.setLineDash([]);
        break;
      case "f":
        trace(ctx, prim.p);
        ctx.fillStyle = css(prim.c);
        ctx.fill(prim.e ? "evenodd" : "nonzero");
        break;
      case "x":
        drawText(ctx, prim);
        break;
      case "d": {
        ctx.fillStyle = css(prim.c);
        const half = prim.z / 2;
        ctx.beginPath();
        for (let i = 0; i + 1 < prim.p.length; i += 2) {
          ctx.rect(prim.p[i] - half, prim.p[i + 1] - half, prim.z, prim.z);
        }
        ctx.fill();
        break;
      }
    }
  }
}
