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
  nextChange(): number;
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
  guide(): string;
  walkthrough(method: string, groupID: string): string;
  mapleMathML(code: string): string;
  toolIcon(id: string, active: boolean): string;
  toolGroups(): string;
  chooseMode(mode: string): void;
  logicCircuit(output: number, form: string): string;
  calculator(): string;
  setCalculator(field: string, value: string): void;
  calculatorFromCircuit(output: number, form: string): void;
  drawCalculatorCircuit(): boolean;
  setLibrary(storage: string): void;
  libraryStorage(): string;
  libraryList(): string;
  addToLibrary(key: string): string;
  selectedBlock(): string;
  removeFromLibrary(id: string): void;
  placeFromLibrary(id: string): void;
  exportLibrary(id: string): string;
  importLibrary(text: string): string;
  leaveBlockTo(index: number): void;
}

interface TextLine { id: string; text: string; isMath: boolean }
interface TextBoxState { id: string; x: number; y: number; scale: number; selected: boolean; lines: TextLine[] }
interface State {
  tool: string;
  /** "analog" or "digital"; null while the start page is shown. */
  mode: string | null;
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
  /** The way into the block being edited ("Ark", then each block); empty on the document's sheet. */
  blockTrail: string[];
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
  { id: "toggleSwitch", name: "Kontakt", action: "toggleSwitch" },
  { id: "pushButton", name: "Trykknap", action: "pushButton" },
  { id: "resistor", name: "Modstand", action: "resistor" },
  { id: "capacitor", name: "Kondensator", action: "capacitor" },
  { id: "inductor", name: "Spole", action: "inductor" },
  { id: "voltageSource", name: "Spændingskilde", action: "voltageSource" },
  { id: "currentSource", name: "Strømkilde", action: "currentSource" },
  { id: "signalGenerator", name: "Signalgenerator", action: "signalGenerator" },
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
  { id: "gate-and", name: "AND-gate", action: "andGate" },
  { id: "gate-or", name: "OR-gate", action: "orGate" },
  { id: "gate-not", name: "NOT-gate (inverter)", action: "notGate" },
  { id: "gate-nand", name: "NAND-gate", action: "nandGate" },
  { id: "gate-nor", name: "NOR-gate", action: "norGate" },
  { id: "gate-xor", name: "XOR-gate", action: "xorGate" },
  { id: "gate-xnor", name: "XNOR-gate", action: "xnorGate" },
  { id: "gate-input", name: "Indgang", action: "logicInput" },
  { id: "gate-output", name: "Udgang", action: "logicOutput" },
  { id: "gate-block", name: "Blok (modul)", action: "logicBlock" },
  { id: "gate-high", name: "5V (altid 1)", action: "logicHigh" },
  { id: "gate-low", name: "GND (altid 0)", action: "logicLow" },
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
      <button data-cmd="report" id="reportButton" class="analogOnly">Beregning</button>
      <button data-cmd="walkthrough" class="analogOnly">Gennemgang og Maple</button>
      <button data-cmd="logic" id="logicButton" class="digitalOnly" title="Sandhedstabel og Karnaugh-kort for kredsløbet, og lommeregneren">Sandhedstabel</button>
      <button data-cmd="library" class="digitalOnly" title="Dine gemte blokke: placér, gem, eksportér og importér">Bibliotek</button>
    </div>
    <div class="spacer"></div>
    <span id="fileName">Uden navn</span>
    <button data-cmd="guide" title="Sådan bruger du JouleSketch">ⓘ</button>
    <button data-cmd="settings" title="Indstillinger">⚙</button>
  </header>
  <main>
    <nav id="palette"></nav>
    <div id="sheet">
      <canvas id="canvas"></canvas>
      <div id="textLayer"></div>
      <div id="toolOptions"></div>
      <div id="blockTrail" hidden></div>
    </div>
    <aside id="walkPanel" hidden></aside>
    <aside id="logicPanel" hidden></aside>
    <div id="startPage" hidden>
      <h1>Hvad vil du tegne?</h1>
      <p class="muted">Vælg, hvad arket skal bruges til. Valget gemmes i filen.</p>
      <div class="cards">
        <button data-mode="analog">
          <canvas data-preview="analog"></canvas>
          <strong>Analog</strong>
          <span>Modstande, kilder, dioder, kondensatorer og spoler. Programmet beregner spændinger, strømme og effekter og viser udregningen og Maple-koden.</span>
          <em>Opret analogt ark</em>
        </button>
        <button data-mode="digital">
          <canvas data-preview="digital"></canvas>
          <strong>Digital</strong>
          <span>Logiske gates – AND, OR, NOT, NAND, NOR, XOR og XNOR. Sandhedstabeller og Karnaugh-kort for det, du tegner, og en lommeregner, der finder de gates, en sandhedstabel kræver.</span>
          <em>Opret digitalt ark</em>
        </button>
      </div>
    </div>
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
const logicPanel = document.getElementById("logicPanel")!;
const startPage = document.getElementById("startPage")!;

// MARK: - Starting the Swift part

const { exports } = await init();
const app: JouleApp = new exports.JouleApp();
app.setSettings(JSON.stringify(settings));
app.setLibrary(localStorage.getItem("blockLibrary") ?? "");
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
    paintSheet();
    state = JSON.parse(app.state());
    updateChrome();
    updateTextBoxes();
    keepBlinking();
  });
}

/** Paints the sheet's canvas. */
function paintSheet() {
  const ratio = window.devicePixelRatio || 1;
  const { width, height } = sheet.getBoundingClientRect();
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  paint(ctx, app.scene(), SHEET_COLOR, width, height);
}

let blinkTimer = 0;

/** Repaints the sheet when a signal generator next changes something on it. */
function keepBlinking() {
  clearTimeout(blinkTimer);
  const delay = app.nextChange();
  if (delay < 0) return;
  // A moment after the change, so the new piece of the period is drawn.
  blinkTimer = window.setTimeout(() => {
    // A full redraw paints the sheet itself and starts this again.
    if (frameRequested) return;
    paintSheet();
    keepBlinking();
  }, delay + 1);
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
  scheduleLogicRefresh();
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

interface ToolGroupInfo { id: string; title: string; shown: string; tools: string[] }

/** The pen or eraser, whichever was used last. */
let lastDrawTool = "pen";

/**
 * The palette's buttons, from the shared Swift code (ToolGroup) like the Mac
 * palette: tools that belong together share a button showing the one last
 * used. Pen and eraser are only tools on the web, so they get their own.
 */
function toolGroupList(): ToolGroupInfo[] {
  const groups = JSON.parse(app.toolGroups()) as ToolGroupInfo[];
  if (state.tool === "pen" || state.tool === "eraser") lastDrawTool = state.tool;
  groups.push({ id: "drawing", title: "Tegning", shown: lastDrawTool, tools: ["pen", "eraser"] });
  return groups;
}

function toolInfo(id: string) {
  return TOOLS.find((t) => t.id === id) ?? { id, name: id };
}

function buildPalette() {
  palette.innerHTML = "";
  for (const group of toolGroupList()) {
    const button = document.createElement("button");
    button.dataset.group = group.id;
    button.innerHTML = `<canvas class="icon"></canvas><span class="label"></span><kbd></kbd>${group.tools.length > 1 ? `<span class="more">▸</span>` : ""}`;
    button.addEventListener("click", () => {
      const current = toolGroupList().find((g) => g.id === group.id);
      if (!current) return;
      // Clicking the picked button again opens the menu with the group's tools.
      if (current.tools.length > 1 && current.shown === state.tool) {
        openToolMenu(button, current);
        return;
      }
      pickTool(current.shown);
    });
    palette.appendChild(button);
  }
  iconsDrawnFor = "";
  updatePalette();
}

function pickTool(id: string) {
  closeToolMenu();
  app.setToolID(id);
  redraw();
  canvas.focus();
}

/** Shows each button's tool: its icon, name and key, and whether it's picked. */
function updatePalette() {
  for (const group of toolGroupList()) {
    const button = palette.querySelector<HTMLButtonElement>(`button[data-group="${group.id}"]`);
    if (!button) continue;
    const tool = toolInfo(group.shown);
    const key = keyFor(tool.action);
    if (button.dataset.tool !== tool.id) {
      button.dataset.tool = tool.id;
      button.querySelector(".label")!.textContent = tool.name;
      button.querySelector("kbd")!.textContent = key;
      const more = group.tools.length > 1 ? ` · klik igen for ${group.title.toLowerCase()}` : "";
      button.title = (key ? `${tool.name} (${key})` : tool.name) + more;
    }
    button.classList.toggle("active", tool.id === state.tool);
  }
}

const toolMenu = document.createElement("div");
toolMenu.id = "toolMenu";
toolMenu.hidden = true;
document.body.appendChild(toolMenu);

/** A menu next to a palette button with all the tools of its group. */
function openToolMenu(button: HTMLElement, group: ToolGroupInfo) {
  toolMenu.innerHTML = "";
  for (const id of group.tools) {
    const tool = toolInfo(id);
    const key = keyFor(tool.action);
    const item = document.createElement("button");
    item.classList.toggle("active", id === state.tool);
    item.innerHTML = `<canvas class="icon"></canvas><span class="label">${tool.name}</span><kbd>${key}</kbd>`;
    item.addEventListener("click", () => pickTool(id));
    toolMenu.appendChild(item);
    drawIcon(item.querySelector("canvas")!, id, false);
  }
  const rect = button.getBoundingClientRect();
  toolMenu.style.left = `${rect.right + 4}px`;
  toolMenu.style.top = `${rect.top}px`;
  toolMenu.hidden = false;
  // Keep it on the screen.
  const overflow = toolMenu.getBoundingClientRect().bottom - (window.innerHeight - 8);
  if (overflow > 0) toolMenu.style.top = `${Math.max(8, rect.top - overflow)}px`;
}

function closeToolMenu() {
  toolMenu.hidden = true;
}

document.addEventListener("pointerdown", (event) => {
  const target = event.target as Node;
  if (!toolMenu.hidden && !toolMenu.contains(target) && !palette.contains(target)) closeToolMenu();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !toolMenu.hidden) closeToolMenu();
});

/** What the icons were last drawn for: the picked tool, shown tools and resistor style. */
let iconsDrawnFor = "";

function drawIcon(icon: HTMLCanvasElement, id: string, active: boolean) {
  const ratio = window.devicePixelRatio || 1;
  icon.width = Math.round(30 * ratio);
  icon.height = Math.round(24 * ratio);
  const iconContext = icon.getContext("2d")!;
  iconContext.setTransform(ratio, 0, 0, ratio, 0, 0);
  iconContext.clearRect(0, 0, 30, 24);
  paint(iconContext, app.toolIcon(id, active), "transparent", 30, 24);
}

/** Draws the palette's icons with the shared Swift code, the picked one in white. */
function drawToolIcons() {
  const buttons = [...palette.querySelectorAll<HTMLButtonElement>("button")];
  const key = `${state.tool} ${settings.resistorStyle} ${buttons.map((b) => b.dataset.tool).join(",")}`;
  if (iconsDrawnFor === key) return;
  iconsDrawnFor = key;
  for (const button of buttons) {
    const icon = button.querySelector<HTMLCanvasElement>("canvas.icon");
    const id = button.dataset.tool;
    if (!icon || !id) continue;
    drawIcon(icon, id, id === state.tool);
  }
}

buildPalette();

/** The kind of sheet the palette was built for. */
let paletteMode: string | null = null;

function updateChrome() {
  // A new document shows the start page; the palette follows the kind of sheet.
  startPage.hidden = state.mode !== null;
  document.body.dataset.mode = state.mode ?? "start";
  // Inside a block the palette has no inputs and outputs.
  const paletteKey = `${state.mode}${state.blockTrail?.length ? "-block" : ""}`;
  if (paletteKey !== paletteMode) {
    paletteMode = paletteKey;
    buildPalette();
    if (state.mode !== "digital") closeLogicPanel();
    if (state.mode !== "analog") closeWalkPanel();
  }
  updatePalette();
  drawToolIcons();
  (document.querySelector('[data-cmd="undo"]') as HTMLButtonElement).disabled = !state.canUndo;
  (document.querySelector('[data-cmd="redo"]') as HTMLButtonElement).disabled = !state.canRedo;
  (document.querySelector('[data-cmd="delete"]') as HTMLButtonElement).disabled = !state.hasSelection;
  document.getElementById("zoom")!.textContent = `${state.zoom} %`;
  const report = document.getElementById("reportButton")!;
  report.textContent = state.issueCount > 0 ? `Beregning (${state.issueCount})` : "Beregning";
  report.classList.toggle("warning", state.issueCount > 0);
  updateBlockTrail();
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
    case "logic":
      if (logicPanel.hidden) showLogicPanel();
      else closeLogicPanel();
      return;
    case "walkthrough":
      if (walkPanel.hidden) showWalkthrough();
      else closeWalkPanel();
      return;
    case "guide": showGuide(); return;
    case "settings": showSettings(); return;
    case "library": showLibrary(); return;
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
    // A right-click on a symbol opens its editor.
    const request = app.takeEditRequest();
    if (request) openPopover(JSON.parse(request));
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
  type: "component" | "probe" | "current" | "mesh" | "group" | "gate";
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
  /** A switch's position. */
  closed?: boolean;
  /** Whether a push button is normally closed (NC). */
  normallyClosed?: boolean;
  /** A signal generator's frequency and phase. */
  frequency?: string;
  phase?: string;
  waveform?: string;
  /** The waveforms to pick from, from the shared Swift code (SignalWaveform). */
  waveforms?: { id: string; name: string }[];
  hasDutyCycle?: boolean;
  isLowSideOutput?: boolean;
  dutyCycle?: string;
  /** An LED's color, and the colors to pick from (LEDColor, with their knee voltages). */
  ledColor?: string;
  ledColors?: { id: string; name: string }[];
  /** What a voltage point or current shows (MeasureMode), and the modes to pick from. */
  measure?: string;
  measures?: { id: string; name: string }[];
  clockwise?: boolean;
  /** A logic gate, input or output. */
  kind?: string;
  isGate?: boolean;
  allowsMoreInputs?: boolean;
  inputCount?: number;
  minInputs?: number;
  maxInputs?: number;
  high?: boolean;
  /** A block's input and output names, one per line. */
  blockInputs?: string;
  blockOutputs?: string;
  logicValue?: string;
  kinds?: { id: string; name: string }[];
  /** Inside a block its inputs and outputs are named after its terminals. */
  nameLocked?: boolean;
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
  if (info.ledColor !== undefined) {
    const colors = info.ledColors ?? [];
    fields.push(`<label>Farve<select data-field="ledColor">${colors.map((c) => `<option value="${c.id}" ${c.id === info.ledColor ? "selected" : ""}>${escapeHTML(c.name)}</option>`).join("")}</select></label>`);
  }
  if (info.measure !== undefined) {
    const measures = info.measures ?? [];
    fields.push(`<label>Vis<select data-field="measure">${measures.map((m) => `<option value="${m.id}" ${m.id === info.measure ? "selected" : ""}>${escapeHTML(m.name)}</option>`).join("")}</select></label>`);
    fields.push(`<p class="hint">Med en signalgenerator: øjebliksværdien svinger med signalet, middel og RMS er som et multimeter på DC og AC.</p>`);
  }
  if (info.isDependent) fields.push(field("Styres af", "controlName", info.controlName ?? "", info.controlPlaceholder));
  if (info.closed !== undefined) {
    fields.push(`<label class="check"><input type="checkbox" data-field="closed" ${info.closed ? "checked" : ""}> Lukket</label>`);
    fields.push(`<p class="hint">Klik på kontakten med Vælg-værktøjet for at åbne eller lukke den.</p>`);
  }
  if (info.normallyClosed !== undefined) {
    fields.push(`<label class="check"><input type="checkbox" data-field="normallyClosed" ${info.normallyClosed ? "checked" : ""}> Normalt lukket (NC)</label>`);
    fields.push(`<p class="hint">Hold trykknappen nede med Vælg-værktøjet for at ${info.normallyClosed ? "åbne" : "lukke"} den.</p>`);
  }
  if (info.frequency !== undefined) {
    const waveforms = info.waveforms ?? [];
    fields.push(`<label>Bølgeform<select data-field="waveform">${waveforms.map((w) => `<option value="${w.id}" ${w.id === info.waveform ? "selected" : ""}>${escapeHTML(w.name)}</option>`).join("")}</select></label>`);
    if (info.hasDutyCycle) {
      fields.push(field("Duty cycle (%)", "dutyCycle", info.dutyCycle ?? "", "50 %"));
      fields.push(`<div class="error" data-error="dutyCycle"></div>`);
      fields.push(info.isLowSideOutput
        ? `<p class="hint">Ved 0 V er generatoren en low-side udgang (LSO): åben (høj) i duty cyclen og trukket ned til stel resten af perioden. Den skal trækkes op af resten af kredsløbet, fx med en pull-up-modstand.</p>`
        : `<p class="hint">Sæt høj spænding til 0 V for at bruge den som en low-side udgang (LSO).</p>`);
    }
    fields.push(field("Frekvens (Hz)", "frequency", info.frequency, "ukendt"));
    fields.push(`<div class="error" data-error="frequency"></div>`);
    fields.push(field("Fase (°)", "phase", info.phase ?? "", "0 °"));
    fields.push(`<div class="error" data-error="phase"></div>`);
  }
  if (info.type === "component") {
    fields.push(`<label class="check"><input type="checkbox" data-field="showsPower" ${info.showsPower ? "checked" : ""}> Vis effekt${info.power ? ` (${escapeHTML(info.power)})` : ""}</label>`);
    fields.push(`<button data-action="flip">Vend retning</button>`);
  }
  if (info.type === "current" || info.type === "mesh") fields.push(`<button data-action="flip">Vend retning</button>`);
  if (info.type === "gate") {
    if (info.isGate) {
      // A gate has no name; its type and inputs instead.
      fields.splice(1, 1);
      const kinds = info.kinds ?? [];
      fields.push(`<label>Type<select data-field="kind">${kinds.map((k) => `<option value="${k.id}" ${k.id === info.kind ? "selected" : ""}>${escapeHTML(k.name)}</option>`).join("")}</select></label>`);
      if (info.allowsMoreInputs) {
        fields.push(`<label>Indgange<input type="number" data-field="inputCount" min="${info.minInputs}" max="${info.maxInputs}" value="${info.inputCount}"></label>`);
      }
    } else if (info.kind === "high" || info.kind === "low") {
      // A flag has no name; just its fixed value.
      fields.splice(1, 1);
      fields.push(`<p class="hint">${info.kind === "high" ? "Det, der forbindes til 5V, er altid 1. Alle 5V-flag er det samme signal." : "Det, der forbindes til GND, er altid 0. Alle GND-flag er det samme signal."}</p>`);
    } else if (info.kind === "block") {
      fields.push(`<label>Indgange<textarea data-field="blockInputs" rows="5">${escapeHTML(info.blockInputs ?? "")}</textarea></label>`);
      fields.push(`<label>Udgange<textarea data-field="blockOutputs" rows="5">${escapeHTML(info.blockOutputs ?? "")}</textarea></label>`);
      fields.push(`<p class="hint">Ét navn pr. linje, oppefra. En tom linje giver et mellemrum uden ben. Ledningerne følger med, når benene flyttes.</p>`);
      fields.push(`<button data-action="openBlock" title="Byg, hvad blokken gør (eller dobbeltklik på den)">Åbn blokken</button>`);
      fields.push(`<button data-action="saveToLibrary">Gem i biblioteket</button>`);
      fields.push(`<div class="hint" data-library-message></div>`);
    } else if (info.nameLocked) {
      fields.splice(1, 1, `<label>Navn<input value="${escapeHTML(info.name)}" disabled></label>`, `<p class="hint">Navnet er et af blokkens ben. Ret benene i blokkens egenskaber (højreklik på blokken).</p>`);
      if (info.kind === "input") {
        fields.push(`<label class="check"><input type="checkbox" data-field="high" ${info.high ? "checked" : ""}> Værdi 1</label>`);
      } else {
        fields.push(`<p class="hint">Værdi: ${escapeHTML(info.logicValue ?? "ukendt")}</p>`);
      }
    } else if (info.kind === "input") {
      fields.push(`<label class="check"><input type="checkbox" data-field="high" ${info.high ? "checked" : ""}> Værdi 1</label>`);
      fields.push(`<p class="hint">Klik på indgangen med Vælg-værktøjet for at skifte mellem 0 og 1. Indgange med samme navn er det samme signal.</p>`);
    } else {
      fields.push(`<p class="hint">Værdi: ${escapeHTML(info.logicValue ?? "ukendt")}</p>`);
    }
    fields.push(`<button data-action="flip">Rotér</button>`);
  }
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
  // Another waveform shows other fields, and an LED color sets the value,
  // so the editor is drawn again.
  if ((input.dataset.field === "waveform" || input.dataset.field === "ledColor" || input.dataset.field === "kind") && popover.dataset.item) {
    app.setField(popover.dataset.item, input.dataset.field, input.value);
    changed();
    const rect = popover.getBoundingClientRect();
    const sheetRect = sheet.getBoundingClientRect();
    openPopover({ item: popover.dataset.item, x: rect.left - sheetRect.left - 8, y: rect.top - sheetRect.top, width: 0, height: 0 });
    return;
  }
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
  if (action === "openBlock" && popover.dataset.item) {
    const item = popover.dataset.item;
    closePopover();
    app.setField(item, "openBlock", "");
    changed();
  }
  if (action === "saveToLibrary" && popover.dataset.item) {
    const message = app.addToLibrary(popover.dataset.item);
    saveLibrary();
    const field = popover.querySelector<HTMLElement>("[data-library-message]");
    if (field) field.textContent = message;
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

// MARK: - Blocks and the block library

const blockTrail = document.getElementById("blockTrail")!;

/** Over the sheet while a block's sub-diagram is edited: the way back out, like the Mac app's. */
function updateBlockTrail() {
  const trail = state.blockTrail ?? [];
  blockTrail.hidden = trail.length === 0;
  const html = trail.length === 0 ? "" : `<button data-trail="back" title="Gå ud af blokken (Esc)">‹</button>` + trail.map((name, index) =>
    index === trail.length - 1 ? `<strong>${escapeHTML(name)}</strong>` : `<button class="link" data-trail="${index}">${escapeHTML(name)}</button>`
  ).join(`<span class="muted">›</span>`);
  if (blockTrail.innerHTML !== html) blockTrail.innerHTML = html;
}

blockTrail.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-trail]");
  if (!target) return;
  if (target.dataset.trail === "back") app.command("leaveBlock");
  else app.leaveBlockTo(Number(target.dataset.trail));
  changed();
});

/** Keeps the library in the browser's storage, like the Mac app's settings. */
function saveLibrary() {
  localStorage.setItem("blockLibrary", app.libraryStorage());
}

function download(text: string, name: string) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([text], { type: "application/json" }));
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

const libraryFileName = "JouleSketch-bibliotek.json";

/** The block library: save the selected block, place, export, import and delete blocks. */
function showLibrary(message = "") {
  const entries = JSON.parse(app.libraryList()) as { id: string; name: string; summary: string }[];
  const rows = entries.length
    ? `<ul class="library">${entries.map((e) => `<li><div><strong>${escapeHTML(e.name)}</strong><br><span class="muted">${escapeHTML(e.summary)}</span></div>
        <span><button data-lib="place" data-id="${e.id}" title="Klik på arket for at placere blokken">Placér</button>
        <button data-lib="export" data-id="${e.id}">Eksportér</button>
        <button data-lib="remove" data-id="${e.id}">Slet</button></span></li>`).join("")}</ul>`
    : `<p class="muted">Biblioteket er tomt. Markér en blok på arket, og tryk på Gem markeret blok – eller importér et bibliotek.</p>`;
  showDialog(`<h2>Bibliotek</h2>${rows}
    <div class="buttons">
      <button data-lib="save" ${app.selectedBlock() ? "" : "disabled"}>Gem markeret blok</button>
      <button data-lib="import">Importér…</button>
      <button data-lib="exportAll" ${entries.length ? "" : "disabled"}>Eksportér…</button>
    </div>
    ${message ? `<p class="hint">${escapeHTML(message)}</p>` : ""}`);
}

dialogBody.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-lib]");
  if (!target) return;
  const id = target.dataset.id ?? "";
  switch (target.dataset.lib) {
    case "place":
      app.placeFromLibrary(id);
      dialog.close();
      changed();
      return;
    case "export":
      download(app.exportLibrary(id), libraryFileName);
      return;
    case "exportAll":
      download(app.exportLibrary(""), libraryFileName);
      return;
    case "remove":
      app.removeFromLibrary(id);
      saveLibrary();
      showLibrary();
      return;
    case "save": {
      const message = app.addToLibrary(app.selectedBlock());
      saveLibrary();
      showLibrary(message);
      return;
    }
    case "import": {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".json,application/json";
      input.addEventListener("change", async () => {
        const file = input.files?.[0];
        if (!file) return;
        const message = app.importLibrary(await file.text());
        saveLibrary();
        showLibrary(message);
      });
      input.click();
      return;
    }
  }
});

// MARK: - Dialogs

function showDialog(html: string) {
  dialogBody.innerHTML = `${html}<div class="buttons"><button class="primary" data-close>Luk</button></div>`;
  dialog.showModal();
}

dialog.addEventListener("click", (event) => {
  const target = event.target as HTMLElement;
  if (target === dialog || target.hasAttribute("data-close")) dialog.close();
});

interface GuideSection {
  id: string;
  title: string;
  blocks: (
    | { kind: "text" | "tip"; text: string }
    | { kind: "bullets"; items: string[] }
    | { kind: "keys"; rows: { key: string; action: string }[] }
  )[];
}

/** The guide behind the ⓘ button, from the shared Swift code (UserGuide) like the Mac app's. */
function showGuide() {
  const sections = JSON.parse(app.guide()) as GuideSection[];
  // **bold** in the guide's text.
  const styled = (text: string) => escapeHTML(text).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  const contents = sections.map((s) => `<a href="#guide-${s.id}" data-guide="${s.id}">${escapeHTML(s.title)}</a>`).join("");
  const body = sections.map((section) => {
    const blocks = section.blocks.map((block) => {
      switch (block.kind) {
        case "text": return `<p>${styled(block.text)}</p>`;
        case "tip": return `<p class="tip">💡 ${styled(block.text)}</p>`;
        case "bullets": return `<ul>${block.items.map((item) => `<li>${styled(item)}</li>`).join("")}</ul>`;
        case "keys": return `<table class="keys">${block.rows.map((row) => `<tr><td><kbd>${escapeHTML(row.key)}</kbd></td><td>${styled(row.action)}</td></tr>`).join("")}</table>`;
      }
    }).join("");
    return `<section id="guide-${section.id}"><h3>${escapeHTML(section.title)}</h3>${blocks}</section>`;
  }).join("");
  showDialog(`<div class="guide"><h2>Sådan bruger du JouleSketch</h2><nav class="guideContents">${contents}</nav><div class="guideBody">${body}</div></div>`);
  dialog.classList.add("guideDialog");
  dialog.addEventListener("close", () => dialog.classList.remove("guideDialog"), { once: true });
  dialogBody.querySelectorAll<HTMLAnchorElement>("[data-guide]").forEach((link) =>
    link.addEventListener("click", (event) => {
      event.preventDefault();
      dialogBody.querySelector(`#guide-${link.dataset.guide}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
    }));
}

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
  /** The method shown, and the ones offered (the equivalent resistance only when one is drawn). */
  method: string;
  methods: { id: string; title: string }[];
  unavailable?: string;
  maple: string | null;
  sections?: { title: string; lines: { math: boolean; text: string }[] }[];
}

let walkMethod = "nodal";
let walkGroup = "";

function showWalkthrough() {
  const groups = JSON.parse(app.groups()) as { id: string; name: string }[];
  const walk = JSON.parse(app.walkthrough(walkMethod, walkGroup)) as Walk;
  const shown = walk.method;
  const header = `
    <h2>Gennemgang og Maple</h2>
    <div class="segmented">${walk.methods.map(({ id, title }) => `<button data-method="${id}" class="${id === shown ? "active" : ""}">${title}</button>`).join("")}</div>
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
  const bindings = JSON.parse(app.keyBindingList()) as { action: string; name: string; key: string; command: boolean; shift: boolean; conflict: boolean; mode: string | null }[];
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
    ${[[null, "Alle ark"], ["analog", "Analoge ark"], ["digital", "Digitale ark"]].map(([mode, title]) => `
    <h4>${title}</h4>
    <table class="keys">${bindings.filter((b) => b.mode === mode).map((b) => `
      <tr class="${b.conflict ? "conflict" : ""}"><td>${escapeHTML(b.name)}</td>
      <td>${b.command ? "Ctrl+" : ""}${b.shift ? "Shift+" : ""}<input class="key" data-action="${b.action}" value="${escapeHTML(b.key)}" maxlength="1"></td></tr>`).join("")}
    </table>`).join("")}
    <p class="hint">Analoge og digitale værktøjer må gerne dele en tast.</p>
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

// MARK: - Start page

startPage.addEventListener("click", (event) => {
  const button = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-mode]");
  if (!button) return;
  app.chooseMode(button.dataset.mode!);
  changed();
  canvas.focus();
});

/** The small drawings on the start page's cards, from the shared Swift code. */
for (const preview of startPage.querySelectorAll<HTMLCanvasElement>("canvas[data-preview]")) {
  const ratio = window.devicePixelRatio || 1;
  preview.width = 60 * ratio;
  preview.height = 48 * ratio;
  const context = preview.getContext("2d")!;
  context.setTransform(ratio * 2, 0, 0, ratio * 2, 0, 0);
  paint(context, app.toolIcon(preview.dataset.preview === "digital" ? "gate-and" : "resistor", false), "transparent", 30, 24);
}

// MARK: - Truth tables and Karnaugh maps

interface LogicAnalysis {
  output: string;
  form: string;
  expression: string;
  isConstant: boolean;
  groupCount: number;
  maxGroups: number;
  gates: string[];
  mapNote?: string;
  map?: {
    rowVariables: string;
    columnVariables: string;
    rowLabels: string[];
    columnLabels: string[];
    cells: { m: number; v: string }[][];
    groups: { color: string; inset: number; blocks: { row: number; column: number; rows: number; columns: number }[] }[];
  };
  steps: { text: string; expression: string | null; color: string | null }[];
}

interface LogicCircuit {
  variables: string[];
  issues: string[];
  message?: string;
  output?: number;
  outputs?: { name: string; values: string[] }[];
  drawn?: string | null;
  canUseInCalculator?: boolean;
  analysis?: LogicAnalysis;
}

interface Calculator {
  variables: string[];
  outputName: string;
  form: string;
  minVariables: number;
  maxVariables: number;
  values: string[];
  analysis: LogicAnalysis;
}

let logicTab: "circuit" | "calculator" = "circuit";
let logicOutput = 0;
let circuitForm = "sumOfProducts";
let drawFailed = false;

const bold = (text: string) => escapeHTML(text).replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");

/** A truth table: the row number, the inputs and the output columns. */
function truthTableHTML(variables: string[], outputs: { name: string; values: string[] }[], editable: boolean, highlighted = -1): string {
  const rows = 1 << variables.length;
  const head = `<tr><th class="muted">m</th>${variables.map((v) => `<th>${escapeHTML(v)}</th>`).join("")}${outputs.map((o, i) => `<th class="${i === highlighted ? "highlight" : ""}">${escapeHTML(o.name)}</th>`).join("")}</tr>`;
  let body = "";
  for (let row = 0; row < rows; row++) {
    const bits = variables.map((_, i) => `<td>${(row >> (variables.length - 1 - i)) & 1}</td>`).join("");
    const values = outputs.map((o, i) => {
      const value = o.values[row] ?? "?";
      const cls = `value v${value === "X" ? "x" : value === "?" ? "q" : value} ${i === highlighted ? "highlight" : ""}`;
      return editable && i === 0
        ? `<td><button class="${cls}" data-row="${row}" title="Klik for at skifte mellem 0, 1 og X">${value}</button></td>`
        : `<td class="${cls}">${value}</td>`;
    }).join("");
    body += `<tr><td class="muted">${row}</td>${bits}${values}</tr>`;
  }
  return `<div class="tableScroll"><table class="truthTable">${head}${body}</table></div>`;
}

/** A Karnaugh map with the groups drawn around their cells. */
function karnaughHTML(map: NonNullable<LogicAnalysis["map"]>): string {
  const cell = 40;
  const header = { width: 54, height: 40 };
  const columns = map.columnLabels.length;
  const rows = map.rowLabels.length;
  let html = `<div class="kmap" style="width:${header.width + columns * cell + 2}px;height:${header.height + rows * cell + 2}px">`;
  html += `<div class="corner" style="width:${header.width}px;height:${header.height}px"><span class="rowVars">${escapeHTML(map.rowVariables)}</span><span class="colVars">${escapeHTML(map.columnVariables)}</span></div>`;
  map.columnLabels.forEach((label, i) => {
    html += `<div class="label" style="left:${header.width + i * cell}px;top:${header.height - 22}px;width:${cell}px">${label}</div>`;
  });
  map.rowLabels.forEach((label, i) => {
    html += `<div class="label" style="left:0;top:${header.height + i * cell + cell / 2 - 9}px;width:${header.width - 6}px;text-align:right">${label}</div>`;
  });
  map.cells.forEach((cells, r) => cells.forEach((c, k) => {
    html += `<div class="cell v${c.v === "X" ? "x" : c.v}" style="left:${header.width + k * cell}px;top:${header.height + r * cell}px;width:${cell}px;height:${cell}px">${c.v}<small>${c.m}</small></div>`;
  }));
  for (const group of map.groups) {
    for (const block of group.blocks) {
      const x = header.width + block.column * cell + group.inset;
      const y = header.height + block.row * cell + group.inset;
      html += `<div class="group" style="left:${x}px;top:${y}px;width:${block.columns * cell - 2 * group.inset}px;height:${block.rows * cell - 2 * group.inset}px;border-color:${group.color};background:${group.color.replace("rgb", "rgba").replace(")", ", 0.12)")}"></div>`;
    }
  }
  return html + "</div>";
}

/** The smallest expression, the gates it needs, the map and the steps. */
function analysisHTML(analysis: LogicAnalysis): string {
  const forms = [["sumOfProducts", "SOP (ettaller)"], ["productOfSums", "POS (nuller)"]];
  return `
    <div class="segmented">${forms.map(([id, name]) => `<button data-form="${id}" class="${id === analysis.form ? "active" : ""}">${name}</button>`).join("")}</div>
    <h4>Mindste udtryk</h4><div class="expr">${analysis.expression}</div>
    <h4>Du skal bruge</h4>
    ${analysis.gates.length ? `<ul>${analysis.gates.map((g) => `<li>${escapeHTML(g)}</li>`).join("")}</ul>` : `<p class="muted">Ingen gates – udgangen er konstant.</p>`}
    ${analysis.map ? `<h4>Karnaugh-kort</h4>${karnaughHTML(analysis.map)}` : analysis.mapNote ? `<p class="hint">${escapeHTML(analysis.mapNote)}</p>` : ""}
    <h4>Sådan findes udtrykket</h4>
    ${analysis.steps.map((step) => `<div class="step">${step.color ? `<span class="dot" style="background:${step.color}"></span>` : ""}<div><p>${bold(step.text)}</p>${step.expression ? `<div class="expr small">${step.expression}</div>` : ""}</div></div>`).join("")}`;
}

function showLogicPanel() {
  const tabs = `<div class="logicTabs"><div class="segmented">
      <button data-tab="circuit" class="${logicTab === "circuit" ? "active" : ""}">Kredsløbet</button>
      <button data-tab="calculator" class="${logicTab === "calculator" ? "active" : ""}">Lommeregner</button>
    </div><button data-logic-close title="Luk sandhedstabellen">✕</button></div>`;
  let body = "";
  if (logicTab === "circuit") {
    const info = JSON.parse(app.logicCircuit(logicOutput, circuitForm)) as LogicCircuit;
    body = `<h2>Sandhedstabel for kredsløbet</h2>`;
    if (info.message) {
      body += `<p class="muted">${escapeHTML(info.message)}</p>`;
    } else {
      body += info.issues.map((issue) => `<div class="issue warning"><p>${escapeHTML(issue)}</p></div>`).join("");
      const outputs = info.outputs ?? [];
      if (outputs.length > 1) {
        body += `<label>Udgang <select id="logicOutput">${outputs.map((o, i) => `<option value="${i}" ${i === info.output ? "selected" : ""}>${escapeHTML(o.name)}</option>`).join("")}</select></label>`;
      }
      body += truthTableHTML(info.variables, outputs, false, outputs.length > 1 ? info.output ?? 0 : -1);
      if (info.drawn) body += `<h4>Udtrykket fra tegningen</h4><div class="expr">${info.drawn}</div>`;
      if (info.analysis) {
        body += analysisHTML(info.analysis);
        if (info.canUseInCalculator) body += `<div class="buttons left"><button data-use-calculator>Brug i lommeregneren</button></div>`;
      }
    }
  } else {
    const calc = JSON.parse(app.calculator()) as Calculator;
    const analysis = calc.analysis;
    body = `<h2>Lommeregner</h2>
      <p class="muted">Skriv den sandhedstabel, kredsløbet skal opfylde. Klik på udgangens felter for at skifte mellem 0, 1 og X (don't care).</p>
      <div class="row">
        <label>Indgange <input type="number" id="calcCount" min="${calc.minVariables}" max="${calc.maxVariables}" value="${calc.variables.length}"></label>
        <label>Udgang <input id="calcName" value="${escapeHTML(calc.outputName)}" size="6"></label>
      </div>
      <div class="buttons left"><button data-fill="0">Alle 0</button><button data-fill="1">Alle 1</button><button data-fill="X">Alle X</button></div>
      ${truthTableHTML(calc.variables, [{ name: analysis.output, values: calc.values }], true)}
      ${analysisHTML(analysis)}
      <div class="buttons left"><button class="primary" data-draw ${analysis.isConstant ? "disabled" : ""}>Tegn kredsløbet på arket</button></div>
      ${analysis.isConstant ? `<p class="hint">Udgangen er konstant, så der er ingen gates at tegne.</p>` : drawFailed ? `<p class="hint warning">Kredsløbet har for mange grupper til at blive tegnet (højst ${analysis.maxGroups}).</p>` : ""}`;
  }
  const scroll = logicPanel.scrollTop;
  logicPanel.innerHTML = tabs + body;
  logicPanel.scrollTop = scroll;
  logicPanel.hidden = false;
}

function closeLogicPanel() {
  if (logicPanel.hidden) return;
  logicPanel.hidden = true;
  logicPanel.innerHTML = "";
}

let logicRefreshTimer = 0;
/** The truth table follows the drawing as it is edited. */
function scheduleLogicRefresh() {
  if (logicPanel.hidden) return;
  clearTimeout(logicRefreshTimer);
  logicRefreshTimer = window.setTimeout(() => {
    if (!logicPanel.hidden && !logicPanel.contains(document.activeElement)) showLogicPanel();
  }, 150);
}

logicPanel.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("button");
  if (!target) return;
  if (target.hasAttribute("data-logic-close")) {
    closeLogicPanel();
    return;
  }
  if (target.dataset.tab) logicTab = target.dataset.tab as typeof logicTab;
  if (target.dataset.form) {
    if (logicTab === "circuit") circuitForm = target.dataset.form;
    else app.setCalculator("form", target.dataset.form);
  }
  if (target.dataset.row) app.setCalculator("cycle", target.dataset.row);
  if (target.dataset.fill) app.setCalculator("fill", target.dataset.fill);
  if (target.hasAttribute("data-use-calculator")) {
    app.calculatorFromCircuit(logicOutput, circuitForm);
    logicTab = "calculator";
  }
  if (target.hasAttribute("data-draw")) {
    drawFailed = !app.drawCalculatorCircuit();
    changed();
  } else if (target.dataset.row || target.dataset.fill || target.dataset.form) {
    drawFailed = false;
  }
  showLogicPanel();
});

logicPanel.addEventListener("change", (event) => {
  const target = event.target as HTMLInputElement;
  if (target.id === "logicOutput") logicOutput = Number(target.value);
  if (target.id === "calcCount") app.setCalculator("count", target.value);
  if (target.id === "calcName") app.setCalculator("name", target.value);
  drawFailed = false;
  showLogicPanel();
});

redraw();
