// The web (Windows) version of JouleSketch. The circuit, editing, gestures,
// drawing and calculation all live in the shared Swift code (see
// Web/Bridge/main.swift); this file only connects the page to it.

import "./style.css";
import { paint } from "./render";
import { renderMath } from "./latex";
// Built from the Swift package by ../build.sh.
// @ts-ignore – generated at build time
import { init } from "../core/index.js";

interface JouleApp {
  open(json: string): string;
  save(): string;
  newDocument(): void;
  setSettings(json: string): void;
  setViewSize(width: number, height: number): void;
  zoom(factor: number, x: number, y: number): void;
  zoomAroundCenter(factor: number): void;
  resetView(): void;
  pan(dx: number, dy: number): void;
  pointerDown(x: number, y: number, command: boolean, shift: boolean): void;
  pointerMove(x: number, y: number, command: boolean, shift: boolean): void;
  pointerUp(x: number, y: number, command: boolean, shift: boolean): void;
  pointerLeave(): void;
  rightDown(x: number, y: number, command: boolean): void;
  rightMove(x: number, y: number): void;
  rightUp(): void;
  cancelDrag(): void;
  key(characters: string): boolean;
  setToolID(id: string): void;
  command(name: string): void;
  keyBindingList(): string;
  setKeyBinding(action: string, key: string): string;
  resetKeyBindings(): string;
  setPen(color: number, size: number): void;
  scene(): string;
  state(): string;
  takeEditRequest(): string;
  endEdit(): void;
  inspect(key: string): string;
  setField(key: string, field: string, text: string): string;
  setTextBoxSize(id: string, width: number, height: number): void;
  beginEditingTextBox(id: string): void;
  endTextEditing(): void;
  setTextBoxLines(id: string, json: string): void;
  report(): string;
  groups(): string;
  walkthrough(method: string, groupID: string): string;
  mapleMathML(code: string): string;
  toolIcon(id: string, active: boolean): string;
}

interface TextLine { id: string; text: string; isMath: boolean }
interface TextBoxState { id: string; x: number; y: number; scale: number; selected: boolean; lines: TextLine[] }
interface State {
  tool: string;
  canUndo: boolean;
  canRedo: boolean;
  hasSelection: boolean;
  selection: string | null;
  isRouting: boolean;
  placesVoltageDrops: boolean;
  meshClockwise: boolean;
  zoom: number;
  editing: string | null;
  isComplete: boolean;
  issueCount: number;
  textBoxes: TextBoxState[];
}

// MARK: - Settings, kept in the browser like the Mac app's UserDefaults

interface Settings {
  resistorStyle: "iec" | "ansi";
  showGrid: boolean;
  studyMode: boolean;
  pageWidth: number;
  pageHeight: number;
  keyBindings: string;
  /** The walkthrough in a panel beside the sheet instead of a window over it. */
  walkSideBySide: boolean;
}

const defaultSettings: Settings = { resistorStyle: "iec", showGrid: true, studyMode: false, pageWidth: 100, pageHeight: 100, keyBindings: "", walkSideBySide: false };

function loadSettings(): Settings {
  try {
    return { ...defaultSettings, ...JSON.parse(localStorage.getItem("settings") ?? "{}") };
  } catch {
    return { ...defaultSettings };
  }
}

let settings = loadSettings();

function saveSettings() {
  localStorage.setItem("settings", JSON.stringify(settings));
  app.setSettings(JSON.stringify(settings));
  redraw();
}

// MARK: - Page structure

const SHEET_COLOR = "rgb(244, 243, 239)";

// Icons are drawn by the shared Swift code (ToolIconScene), like the Mac palette.
const TOOLS: { id: string; name: string; action?: string }[] = [
  { id: "select", name: "Vælg", action: "select" },
  { id: "wire", name: "Ledning", action: "wire" },
  { id: "resistor", name: "Modstand", action: "resistor" },
  { id: "voltageSource", name: "Spændingskilde", action: "voltageSource" },
  { id: "currentSource", name: "Strømkilde", action: "currentSource" },
  { id: "vcvs", name: "Spændingsstyret spændingskilde" },
  { id: "ccvs", name: "Strømstyret spændingskilde" },
  { id: "vccs", name: "Spændingsstyret strømkilde" },
  { id: "cccs", name: "Strømstyret strømkilde" },
  { id: "diode", name: "Diode", action: "diode" },
  { id: "led", name: "Lysdiode (LED)", action: "led" },
  { id: "ground", name: "Stel (0 V)", action: "ground" },
  { id: "current", name: "Strøm i ledning", action: "current" },
  { id: "probe", name: "Spændingspunkt", action: "probe" },
  { id: "power", name: "Effekt i komponent", action: "power" },
  { id: "equivalent", name: "Samlet modstand (Req)", action: "equivalent" },
  { id: "text", name: "Tekst og udregning", action: "text" },
  { id: "mesh", name: "Maskestrøm", action: "mesh" },
  { id: "groupArea", name: "Gruppe", action: "groupArea" },
  { id: "pen", name: "Pen" },
  { id: "eraser", name: "Viskelæder" },
];

document.body.innerHTML = `
  <header id="toolbar">
    <div class="group">
      <button data-cmd="new" title="Nyt kredsløb">Ny</button>
      <button data-cmd="open" title="Åbn (Ctrl+O)">Åbn…</button>
      <button data-cmd="save" title="Gem (Ctrl+S)">Gem</button>
    </div>
    <div class="group">
      <button data-cmd="undo" title="Fortryd (Ctrl+Z)">↶</button>
      <button data-cmd="redo" title="Gendan (Ctrl+Y)">↷</button>
      <button data-cmd="rotate" title="Rotér / vend retning">⟳</button>
      <button data-cmd="delete" title="Slet (Delete)">🗑</button>
    </div>
    <div class="group">
      <button data-cmd="zoomOut" title="Zoom ud">−</button>
      <button data-cmd="zoomReset" id="zoom" title="Nulstil visning">100 %</button>
      <button data-cmd="zoomIn" title="Zoom ind">+</button>
    </div>
    <div class="group">
      <button data-cmd="report" id="reportButton">Beregning</button>
      <button data-cmd="walkthrough">Gennemgang og Maple</button>
    </div>
    <div class="spacer"></div>
    <span id="fileName">Uden navn</span>
    <button data-cmd="settings" title="Indstillinger">⚙</button>
  </header>
  <main>
    <nav id="palette"></nav>
    <div id="sheet">
      <canvas id="canvas"></canvas>
      <div id="textLayer"></div>
      <div id="toolOptions"></div>
    </div>
    <aside id="walkPanel" hidden></aside>
  </main>
  <div id="popover" hidden></div>
  <dialog id="dialog"><div id="dialogBody"></div></dialog>
  <input type="file" id="fileInput" accept=".joulesketch,application/json" hidden>
`;

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
const sheet = document.getElementById("sheet")!;
const textLayer = document.getElementById("textLayer")!;
const popover = document.getElementById("popover")!;
const dialog = document.getElementById("dialog") as HTMLDialogElement;
const dialogBody = document.getElementById("dialogBody")!;
const palette = document.getElementById("palette")!;
const toolOptions = document.getElementById("toolOptions")!;
const walkPanel = document.getElementById("walkPanel")!;

// MARK: - Starting the Swift part

const { exports } = await init();
const app: JouleApp = new exports.JouleApp();
app.setSettings(JSON.stringify(settings));
document.getElementById("loading")?.remove();

let state: State = JSON.parse(app.state());
let fileHandle: FileSystemFileHandle | null = null;
let fileName = "Uden navn";
let isDirty = false;

// The document survives reloading the page.
const autosaved = localStorage.getItem("autosave");
if (autosaved) {
  app.open(autosaved);
  fileName = localStorage.getItem("autosaveName") ?? fileName;
}

// MARK: - Drawing

let frameRequested = false;

/** Draws the sheet and refreshes everything around it on the next frame. */
function redraw() {
  if (frameRequested) return;
  frameRequested = true;
  requestAnimationFrame(() => {
    frameRequested = false;
    const ratio = window.devicePixelRatio || 1;
    const { width, height } = sheet.getBoundingClientRect();
    if (canvas.width !== Math.round(width * ratio) || canvas.height !== Math.round(height * ratio)) {
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      app.setViewSize(width, height);
    }
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    paint(ctx, app.scene(), SHEET_COLOR, width, height);
    state = JSON.parse(app.state());
    updateChrome();
    updateTextBoxes();
  });
}

/** Call after anything that may have changed the document. */
function changed() {
  isDirty = true;
  scheduleAutosave();
  redraw();
}

let autosaveTimer = 0;
function scheduleAutosave() {
  scheduleWalkRefresh();
  clearTimeout(autosaveTimer);
  autosaveTimer = window.setTimeout(() => {
    localStorage.setItem("autosave", app.save());
    localStorage.setItem("autosaveName", fileName);
  }, 500);
}

new ResizeObserver(() => redraw()).observe(sheet);

// MARK: - Toolbar and palette

function keyFor(action: string | undefined): string {
  if (!action) return "";
  const binding = (JSON.parse(app.keyBindingList()) as { action: string; key: string }[]).find((b) => b.action === action);
  return binding?.key.toUpperCase() ?? "";
}

function buildPalette() {
  palette.innerHTML = "";
  for (const tool of TOOLS) {
    const button = document.createElement("button");
    button.dataset.tool = tool.id;
    const key = keyFor(tool.action);
    button.title = key ? `${tool.name} (${key})` : tool.name;
    button.innerHTML = `<canvas class="icon"></canvas><span class="label">${tool.name}</span>${key ? `<kbd>${key}</kbd>` : ""}`;
    button.addEventListener("click", () => {
      app.setToolID(tool.id);
      redraw();
      canvas.focus();
    });
    palette.appendChild(button);
  }
  iconsDrawnFor = "";
}

/** What the icons were last drawn for: the picked tool and resistor style. */
let iconsDrawnFor = "";

/** Draws the palette's icons with the shared Swift code, the picked one in white. */
function drawToolIcons() {
  const key = `${state.tool} ${settings.resistorStyle}`;
  if (iconsDrawnFor === key) return;
  iconsDrawnFor = key;
  const ratio = window.devicePixelRatio || 1;
  for (const button of palette.querySelectorAll<HTMLButtonElement>("button")) {
    const icon = button.querySelector<HTMLCanvasElement>("canvas.icon");
    const id = button.dataset.tool;
    if (!icon || !id) continue;
    icon.width = Math.round(30 * ratio);
    icon.height = Math.round(24 * ratio);
    const iconContext = icon.getContext("2d")!;
    iconContext.setTransform(ratio, 0, 0, ratio, 0, 0);
    iconContext.clearRect(0, 0, 30, 24);
    paint(iconContext, app.toolIcon(id, id === state.tool), "transparent", 30, 24);
  }
}

buildPalette();

function updateChrome() {
  for (const button of palette.querySelectorAll<HTMLButtonElement>("button")) {
    button.classList.toggle("active", button.dataset.tool === state.tool);
  }
  drawToolIcons();
  (document.querySelector('[data-cmd="undo"]') as HTMLButtonElement).disabled = !state.canUndo;
  (document.querySelector('[data-cmd="redo"]') as HTMLButtonElement).disabled = !state.canRedo;
  (document.querySelector('[data-cmd="delete"]') as HTMLButtonElement).disabled = !state.hasSelection;
  document.getElementById("zoom")!.textContent = `${state.zoom} %`;
  const report = document.getElementById("reportButton")!;
  report.textContent = state.issueCount > 0 ? `Beregning (${state.issueCount})` : "Beregning";
  report.classList.toggle("warning", state.issueCount > 0);
  document.getElementById("fileName")!.textContent = fileName + (isDirty ? " •" : "");
  document.title = `${fileName} – JouleSketch`;

  // Extra choices for some tools, like the Mac app's palette.
  let options = "";
  if (state.tool === "probe") {
    options = `<label><input type="checkbox" data-opt="voltageDrops" ${state.placesVoltageDrops ? "checked" : ""}> Spændingsfald (+ og −)</label>`;
  } else if (state.tool === "mesh") {
    options = `<button data-opt="meshDirection">${state.meshClockwise ? "↻ Med uret" : "↺ Mod uret"}</button>`;
  } else if (state.tool === "pen") {
    options = [0, 1, 2, 3, 4].map((c) => `<button class="pen pen${c}" data-pen="${c}"></button>`).join("")
      + `<select data-opt="penSize">${["Tynd", "Normal", "Mellem", "Tyk", "Meget tyk"].map((n, i) => `<option value="${i}" ${i === penSize ? "selected" : ""}>${n}</option>`).join("")}</select>`;
  }
  if (toolOptions.dataset.html !== options) {
    toolOptions.dataset.html = options;
    toolOptions.innerHTML = options;
    toolOptions.hidden = options === "";
  }
}

let penColor = 0;
let penSize = 1;
toolOptions.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;
  if (target.dataset.opt === "meshDirection") app.command("toggleMeshDirection");
  if (target.dataset.opt === "voltageDrops") app.command("toggleVoltageDrops");
  if (target.dataset.pen) {
    penColor = Number(target.dataset.pen);
    app.setPen(penColor, penSize);
  }
  redraw();
});
toolOptions.addEventListener("change", (event) => {
  const target = event.target as HTMLSelectElement;
  if (target.dataset.opt === "penSize") {
    penSize = Number(target.value);
    app.setPen(penColor, penSize);
  }
});

document.getElementById("toolbar")!.addEventListener("click", (event) => {
  const button = (event.target as HTMLElement).closest("button");
  if (button?.dataset.cmd) runCommand(button.dataset.cmd);
});

function runCommand(name: string) {
  switch (name) {
    case "new":
      if (isDirty && !confirm("Kassér ændringerne i det nuværende kredsløb?")) return;
      app.newDocument();
      fileHandle = null;
      fileName = "Uden navn";
      isDirty = false;
      scheduleAutosave();
      break;
    case "open": openFile(); return;
    case "save": saveFile(); return;
    case "zoomIn": app.zoomAroundCenter(1.25); break;
    case "zoomOut": app.zoomAroundCenter(0.8); break;
    case "zoomReset": app.resetView(); break;
    case "report": showReport(); return;
    case "walkthrough":
      if (walkPanel.hidden) showWalkthrough();
      else closeWalkPanel();
      return;
    case "settings": showSettings(); return;
    default:
      app.command(name);
      changed();
      return;
  }
  redraw();
}

// MARK: - Files

async function openFile() {
  if (isDirty && !confirm("Kassér ændringerne i det nuværende kredsløb?")) return;
  if ("showOpenFilePicker" in window) {
    try {
      const [handle] = await (window as any).showOpenFilePicker({
        types: [{ description: "JouleSketch-kredsløb", accept: { "application/json": [".joulesketch"] } }],
      });
      const file = await handle.getFile();
      loadText(await file.text(), file.name, handle);
    } catch {
      // Cancelled.
    }
  } else {
    (document.getElementById("fileInput") as HTMLInputElement).click();
  }
}

document.getElementById("fileInput")!.addEventListener("change", async (event) => {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  if (file) loadText(await file.text(), file.name, null);
  input.value = "";
});

function loadText(text: string, name: string, handle: FileSystemFileHandle | null) {
  const error = app.open(text);
  if (error) {
    alert(error);
    return;
  }
  fileHandle = handle;
  fileName = name.replace(/\.joulesketch$/, "");
  isDirty = false;
  scheduleAutosave();
  redraw();
}

async function saveFile() {
  const text = app.save();
  if ("showSaveFilePicker" in window) {
    try {
      if (!fileHandle) {
        fileHandle = await (window as any).showSaveFilePicker({
          suggestedName: `${fileName}.joulesketch`,
          types: [{ description: "JouleSketch-kredsløb", accept: { "application/json": [".joulesketch"] } }],
        });
      }
      const writable = await (fileHandle as any).createWritable();
      await writable.write(text);
      await writable.close();
      fileName = fileHandle!.name.replace(/\.joulesketch$/, "");
    } catch {
      return; // Cancelled.
    }
  } else {
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "application/json" }));
    link.download = `${fileName}.joulesketch`;
    link.click();
    URL.revokeObjectURL(link.href);
  }
  isDirty = false;
  scheduleAutosave();
  redraw();
}

// Files dropped on the window open.
window.addEventListener("dragover", (event) => event.preventDefault());
window.addEventListener("drop", async (event) => {
  event.preventDefault();
  const file = event.dataTransfer?.files[0];
  if (file && (!isDirty || confirm("Kassér ændringerne i det nuværende kredsløb?"))) {
    loadText(await file.text(), file.name, null);
  }
});

window.addEventListener("beforeunload", (event) => {
  if (isDirty) event.preventDefault();
});

// MARK: - Pointer

function local(event: PointerEvent | WheelEvent | MouseEvent): [number, number] {
  const rect = canvas.getBoundingClientRect();
  return [event.clientX - rect.left, event.clientY - rect.top];
}

const isCommand = (event: { ctrlKey: boolean; metaKey: boolean }) => event.ctrlKey || event.metaKey;
let middlePan: [number, number] | null = null;

canvas.tabIndex = 0;
canvas.addEventListener("pointerdown", (event) => {
  closePopover();
  canvas.focus();
  canvas.setPointerCapture(event.pointerId);
  const [x, y] = local(event);
  if (event.button === 0) {
    app.pointerDown(x, y, isCommand(event), event.shiftKey);
  } else if (event.button === 2) {
    app.rightDown(x, y, isCommand(event));
  } else if (event.button === 1) {
    middlePan = [x, y];
  }
  changed();
});

canvas.addEventListener("pointermove", (event) => {
  const [x, y] = local(event);
  if (middlePan) {
    app.pan(x - middlePan[0], y - middlePan[1]);
    middlePan = [x, y];
  } else if (event.buttons & 2) {
    app.rightMove(x, y);
  } else {
    app.pointerMove(x, y, isCommand(event), event.shiftKey);
  }
  redraw();
});

canvas.addEventListener("pointerup", (event) => {
  const [x, y] = local(event);
  if (event.button === 0) {
    app.pointerUp(x, y, isCommand(event), event.shiftKey);
    const request = app.takeEditRequest();
    if (request) openPopover(JSON.parse(request));
  } else if (event.button === 2) {
    app.rightUp();
  } else if (event.button === 1) {
    middlePan = null;
  }
  changed();
});

canvas.addEventListener("pointercancel", () => {
  app.cancelDrag();
  redraw();
});
canvas.addEventListener("pointerleave", () => {
  app.pointerLeave();
  redraw();
});
canvas.addEventListener("contextmenu", (event) => event.preventDefault());

// Two-finger scrolling moves the sheet; pinching (or Ctrl + wheel) zooms.
canvas.addEventListener("wheel", (event) => {
  event.preventDefault();
  if (event.ctrlKey) {
    const [x, y] = local(event);
    app.zoom(Math.exp(-event.deltaY * 0.01), x, y);
  } else {
    app.pan(-event.deltaX, -event.deltaY);
  }
  redraw();
}, { passive: false });

// MARK: - Keyboard

window.addEventListener("keydown", (event) => {
  const target = event.target as HTMLElement;
  const typing = target.closest("input, textarea, select, [contenteditable]") !== null;
  if (isCommand(event)) {
    const key = event.key.toLowerCase();
    const commands: Record<string, string> = { z: event.shiftKey ? "redo" : "undo", y: "redo", s: "save", o: "open" };
    if (!typing) Object.assign(commands, { a: "selectAll", c: "copy", v: "paste" });
    const command = commands[key];
    if (command) {
      event.preventDefault();
      runCommand(command);
    }
    return;
  }
  if (typing || event.altKey) return;
  if (event.key === "Escape") {
    closePopover();
    runCommand("escape");
  } else if (event.key === "Delete" || event.key === "Backspace") {
    event.preventDefault();
    runCommand("delete");
  } else if (event.key.length === 1 && app.key(event.key)) {
    event.preventDefault();
    redraw();
  }
});

window.addEventListener("keyup", () => redraw());

// MARK: - Symbol editor (double-click)

interface Inspection {
  type: "component" | "probe" | "current" | "mesh" | "group";
  item: string;
  title: string;
  name: string;
  value?: string;
  valueTitle?: string;
  computed?: string | null;
  note?: string;
  isDependent?: boolean;
  controlName?: string;
  controlPlaceholder?: string;
  showsPower?: boolean;
  power?: string | null;
  clockwise?: boolean;
}

const escapeHTML = (text: string) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

function openPopover(request: { item: string; x: number; y: number; width: number; height: number }) {
  const json = app.inspect(request.item);
  if (!json) {
    app.endEdit();
    return;
  }
  const info = JSON.parse(json) as Inspection;
  const fields: string[] = [`<h3>${escapeHTML(info.title)}</h3>`, field("Navn", "name", info.name)];
  if (info.valueTitle !== undefined) {
    const placeholder = info.computed ? `${info.computed} (beregnet)` : "ukendt";
    fields.push(field(info.valueTitle, "value", info.value ?? "", placeholder));
    fields.push(`<div class="error" data-error="value"></div>`);
  }
  if (info.isDependent) fields.push(field("Styres af", "controlName", info.controlName ?? "", info.controlPlaceholder));
  if (info.type === "component") {
    fields.push(`<label class="check"><input type="checkbox" data-field="showsPower" ${info.showsPower ? "checked" : ""}> Vis effekt${info.power ? ` (${escapeHTML(info.power)})` : ""}</label>`);
    fields.push(`<button data-action="flip">Vend retning</button>`);
  }
  if (info.type === "current" || info.type === "mesh") fields.push(`<button data-action="flip">Vend retning</button>`);
  if (info.note !== undefined) fields.push(`<label>Note<textarea data-field="note" rows="3">${escapeHTML(info.note)}</textarea></label>`);
  fields.push(`<div class="buttons"><button data-action="close" class="primary">Færdig</button></div>`);

  popover.innerHTML = fields.join("");
  popover.hidden = false;
  popover.dataset.item = info.item;
  const sheetRect = sheet.getBoundingClientRect();
  const left = Math.min(sheetRect.left + request.x + request.width + 8, window.innerWidth - 300);
  popover.style.left = `${Math.max(8, left)}px`;
  popover.style.top = `${Math.max(56, Math.min(sheetRect.top + request.y, window.innerHeight - popover.offsetHeight - 8))}px`;
  (popover.querySelector<HTMLInputElement>('[data-field="value"]') ?? popover.querySelector("input"))?.focus();
  (popover.querySelector<HTMLInputElement>('[data-field="value"]'))?.select();
}

function field(title: string, name: string, value: string, placeholder = ""): string {
  return `<label>${escapeHTML(title)}<input data-field="${name}" value="${escapeHTML(value)}" placeholder="${escapeHTML(placeholder)}" autocomplete="off"></label>`;
}

function closePopover() {
  if (popover.hidden) return;
  popover.hidden = true;
  app.endEdit();
  changed();
}

popover.addEventListener("input", (event) => {
  const input = event.target as HTMLInputElement;
  const name = input.dataset.field;
  if (!name || !popover.dataset.item) return;
  const text = input.type === "checkbox" ? String(input.checked) : input.value;
  const error = app.setField(popover.dataset.item, name, text);
  const errorField = popover.querySelector<HTMLElement>(`[data-error="${name}"]`);
  if (errorField) errorField.textContent = error;
  changed();
});

popover.addEventListener("click", (event) => {
  const action = (event.target as HTMLElement).dataset.action;
  if (action === "close") closePopover();
  if (action === "flip" && popover.dataset.item) {
    app.setField(popover.dataset.item, "flip", "");
    changed();
  }
});

popover.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (event.target as HTMLElement).tagName === "INPUT") closePopover();
  if (event.key === "Escape") closePopover();
});

// MARK: - Text boxes

/** The text boxes lie over the sheet as HTML, like the Mac app's TextBoxView. */
function updateTextBoxes() {
  const seen = new Set<string>();
  for (const box of state.textBoxes) {
    seen.add(box.id);
    let element = textLayer.querySelector<HTMLElement>(`[data-box="${box.id}"]`);
    if (!element) {
      element = document.createElement("div");
      element.className = "textBox";
      element.dataset.box = box.id;
      textLayer.appendChild(element);
    }
    const editing = state.editing === box.id;
    const signature = JSON.stringify([box.lines, editing]);
    if (element.dataset.signature !== signature && !(editing && element.contains(document.activeElement))) {
      element.dataset.signature = signature;
      fillTextBox(element, box, editing);
    }
    element.classList.toggle("editing", editing);
    element.classList.toggle("selected", box.selected);
    element.style.transform = `translate(${box.x}px, ${box.y}px) scale(${box.scale})`;
    const rect = element.getBoundingClientRect();
    app.setTextBoxSize(box.id, rect.width, rect.height);
  }
  for (const element of textLayer.querySelectorAll<HTMLElement>(".textBox")) {
    if (!seen.has(element.dataset.box!)) element.remove();
  }
}

function fillTextBox(element: HTMLElement, box: TextBoxState, editing: boolean) {
  element.innerHTML = "";
  for (const line of box.lines) {
    const row = document.createElement("div");
    row.className = "line";
    if (editing) {
      const toggle = document.createElement("button");
      toggle.textContent = line.isMath ? "∑" : "T";
      toggle.title = line.isMath ? "Math (LaTeX) – skift til tekst" : "Tekst – skift til math (LaTeX)";
      toggle.addEventListener("click", () => {
        line.isMath = !line.isMath;
        commitLines(box);
      });
      const input = document.createElement("input");
      input.value = line.text;
      input.placeholder = line.isMath ? "LaTeX, fx R__eq := R1+R2" : "Tekst";
      input.className = line.isMath ? "math" : "";
      input.addEventListener("input", () => {
        line.text = input.value;
        commitLines(box, false);
      });
      input.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          const index = box.lines.indexOf(line);
          box.lines.splice(index + 1, 0, { id: crypto.randomUUID().toUpperCase(), text: "", isMath: line.isMath });
          commitLines(box);
          focusLine(box.id, index + 1);
        } else if (event.key === "Backspace" && input.value === "" && box.lines.length > 1) {
          event.preventDefault();
          const index = box.lines.indexOf(line);
          box.lines.splice(index, 1);
          commitLines(box);
          focusLine(box.id, Math.max(0, index - 1));
        } else if (event.key === "Escape") {
          app.endTextEditing();
          changed();
        }
      });
      row.append(toggle, input);
      if (line.isMath && line.text) {
        const preview = document.createElement("div");
        preview.className = "preview";
        renderMath(line.text, preview);
        row.appendChild(preview);
      }
    } else if (line.isMath) {
      renderMath(line.text, row);
    } else {
      row.textContent = line.text;
    }
    element.appendChild(row);
  }
  if (editing && !element.contains(document.activeElement)) focusLine(box.id, box.lines.length - 1);
}

function commitLines(box: TextBoxState, rebuild = true) {
  app.setTextBoxLines(box.id, JSON.stringify(box.lines));
  if (rebuild) {
    const element = textLayer.querySelector<HTMLElement>(`[data-box="${box.id}"]`);
    if (element) {
      element.dataset.signature = "";
      fillTextBox(element, box, true);
    }
  }
  changed();
}

function focusLine(boxID: string, index: number) {
  requestAnimationFrame(() => {
    const inputs = textLayer.querySelectorAll<HTMLInputElement>(`[data-box="${boxID}"] input`);
    inputs[index]?.focus();
  });
}

// MARK: - Dialogs

function showDialog(html: string) {
  dialogBody.innerHTML = `${html}<div class="buttons"><button class="primary" data-close>Luk</button></div>`;
  dialog.showModal();
}

dialog.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;
  if (target === dialog || target.hasAttribute("data-close")) dialog.close();
});

interface Report {
  isConsistent: boolean;
  isComplete: boolean;
  unknownCount: number;
  solvedCount: number;
  issues: { kind: string; title: string; detail: string }[];
}

function showReport() {
  const report = JSON.parse(app.report()) as Report;
  const summary = report.isComplete
    ? `<p class="ok">Alt er beregnet (${report.solvedCount} af ${report.unknownCount} ukendte værdier).</p>`
    : `<p>${report.solvedCount} af ${report.unknownCount} ukendte værdier er beregnet.</p>`;
  const issues = report.issues
    .map((issue) => `<div class="issue ${issue.kind}"><strong>${escapeHTML(issue.title)}</strong><p>${escapeHTML(issue.detail)}</p></div>`)
    .join("");
  showDialog(`<h2>Beregning</h2>${summary}${issues}`);
}

interface Walk {
  unavailable?: string;
  maple: string | null;
  sections?: { title: string; lines: { math: boolean; text: string }[] }[];
}

let walkMethod = "nodal";
let walkGroup = "";

function showWalkthrough() {
  const groups = JSON.parse(app.groups()) as { id: string; name: string }[];
  const methods = [["nodal", "Knudepunkt"], ["mesh", "Maske"], ["superposition", "Superposition"]];
  const walk = JSON.parse(app.walkthrough(walkMethod, walkGroup)) as Walk;
  const header = `
    <h2>Gennemgang og Maple</h2>
    <div class="segmented">${methods.map(([id, name]) => `<button data-method="${id}" class="${id === walkMethod ? "active" : ""}">${name}</button>`).join("")}</div>
    ${groups.length ? `<select id="walkGroup"><option value="">Hele dokumentet</option>${groups.map((g) => `<option value="${g.id}" ${g.id === walkGroup ? "selected" : ""}>${escapeHTML(g.name)}</option>`).join("")}</select>` : ""}`;
  const body = walk.unavailable
    ? `<p class="unavailable">${escapeHTML(walk.unavailable)}</p>`
    : `<div id="walkSections"></div>`;
  const maple = walk.maple
    ? `<h3>Maple</h3><div class="buttons left"><button data-copy="maple">Kopiér til Maple (2-D)</button><button data-copy="text">Kopiér som tekst</button></div><pre id="mapleCode">${escapeHTML(walk.maple)}</pre>`
    : "";
  const layout = settings.walkSideBySide
    ? `<button data-layout title="Vis gennemgangen i et vindue over diagrammet">Vis som vindue</button><button data-walk-close title="Luk gennemgangen">✕</button>`
    : `<button data-layout title="Vis gennemgangen ved siden af diagrammet">Vis side om side</button>`;
  const html = `<div class="walkLayout">${layout}</div>` + header + body + maple;
  const container = settings.walkSideBySide ? walkPanel : dialogBody;
  if (settings.walkSideBySide) {
    // Refreshing keeps the place in the walkthrough.
    const scroll = walkPanel.scrollTop;
    walkPanel.innerHTML = html;
    if (walkPanel.hidden) {
      walkPanel.hidden = false;
      if (dialog.open) dialog.close();
    } else {
      walkPanel.scrollTop = scroll;
    }
  } else {
    closeWalkPanel();
    showDialog(html);
  }

  const sections = container.querySelector("#walkSections");
  for (const section of walk.sections ?? []) {
    const element = document.createElement("section");
    element.innerHTML = `<h3>${escapeHTML(section.title)}</h3>`;
    for (const line of section.lines) {
      const row = document.createElement("div");
      row.className = line.math ? "math" : "text";
      if (line.math) renderMath(line.text, row, true);
      else row.textContent = line.text;
      element.appendChild(row);
    }
    sections?.appendChild(element);
  }

  container.querySelectorAll<HTMLButtonElement>("[data-method]").forEach((button) =>
    button.addEventListener("click", () => {
      walkMethod = button.dataset.method!;
      showWalkthrough();
    }));
  container.querySelector("#walkGroup")?.addEventListener("change", (event) => {
    walkGroup = (event.target as HTMLSelectElement).value;
    showWalkthrough();
  });
  container.querySelector("[data-layout]")?.addEventListener("click", () => {
    settings.walkSideBySide = !settings.walkSideBySide;
    saveSettings();
    showWalkthrough();
  });
  container.querySelector("[data-walk-close]")?.addEventListener("click", closeWalkPanel);
  container.querySelectorAll<HTMLButtonElement>("[data-copy]").forEach((button) =>
    button.addEventListener("click", async () => {
      if (!walk.maple) return;
      const text = button.dataset.copy === "maple" ? app.mapleMathML(walk.maple) : walk.maple;
      await navigator.clipboard.writeText(text);
      button.textContent = "✓ Kopieret";
    }));
}

function closeWalkPanel() {
  if (walkPanel.hidden) return;
  walkPanel.hidden = true;
  walkPanel.innerHTML = "";
}

let walkRefreshTimer = 0;
/** The panel follows the drawing as it is edited, once the editing pauses. */
function scheduleWalkRefresh() {
  if (walkPanel.hidden) return;
  clearTimeout(walkRefreshTimer);
  walkRefreshTimer = window.setTimeout(() => {
    if (!walkPanel.hidden) showWalkthrough();
  }, 300);
}

function showSettings() {
  const bindings = JSON.parse(app.keyBindingList()) as { action: string; name: string; key: string; command: boolean; shift: boolean; conflict: boolean }[];
  showDialog(`
    <h2>Indstillinger</h2>
    <h3>Symboler</h3>
    <label>Modstande <select id="setResistor">
      <option value="iec" ${settings.resistorStyle === "iec" ? "selected" : ""}>Europæisk (rektangel)</option>
      <option value="ansi" ${settings.resistorStyle === "ansi" ? "selected" : ""}>Amerikansk (zigzag)</option>
    </select></label>
    <label class="check"><input type="checkbox" id="setGrid" ${settings.showGrid ? "checked" : ""}> Vis gitter</label>
    <label class="check"><input type="checkbox" id="setStudy" ${settings.studyMode ? "checked" : ""}> Studietilstand (skjul beregnede værdier)</label>
    <h3>Side</h3>
    <label>Bredde <input type="number" id="setWidth" min="10" max="1000" step="10" value="${settings.pageWidth}"></label>
    <label>Højde <input type="number" id="setHeight" min="10" max="1000" step="10" value="${settings.pageHeight}"></label>
    <h3>Tastaturgenveje</h3>
    <table class="keys">${bindings.map((b) => `
      <tr class="${b.conflict ? "conflict" : ""}"><td>${escapeHTML(b.name)}</td>
      <td>${b.command ? "Ctrl+" : ""}${b.shift ? "Shift+" : ""}<input class="key" data-action="${b.action}" value="${escapeHTML(b.key)}" maxlength="1"></td></tr>`).join("")}
    </table>
    <button id="resetKeys">Nulstil genveje</button>
  `);
  const update = () => {
    settings.resistorStyle = (document.getElementById("setResistor") as HTMLSelectElement).value as Settings["resistorStyle"];
    settings.showGrid = (document.getElementById("setGrid") as HTMLInputElement).checked;
    settings.studyMode = (document.getElementById("setStudy") as HTMLInputElement).checked;
    settings.pageWidth = Number((document.getElementById("setWidth") as HTMLInputElement).value) || 100;
    settings.pageHeight = Number((document.getElementById("setHeight") as HTMLInputElement).value) || 100;
    saveSettings();
  };
  dialogBody.querySelectorAll("select, input:not(.key)").forEach((input) => input.addEventListener("change", update));
  dialogBody.querySelectorAll<HTMLInputElement>("input.key").forEach((input) =>
    input.addEventListener("input", () => {
      settings.keyBindings = app.setKeyBinding(input.dataset.action!, input.value.toLowerCase());
      saveSettings();
      buildPalette();
      showSettings();
    }));
  document.getElementById("resetKeys")!.addEventListener("click", () => {
    settings.keyBindings = app.resetKeyBindings();
    saveSettings();
    buildPalette();
    showSettings();
  });
}

redraw();
