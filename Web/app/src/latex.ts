import katex from "katex";
import "katex/dist/katex.min.css";

/**
 * Renders a formula written the way JouleSketch writes them (see
 * LatexParser in MathLatex.swift) with KaTeX: "R__eq" is R with the
 * subscript "eq", and "[[kΩ]]" is a unit.
 */
export function renderMath(source: string, element: HTMLElement, display = false) {
  const tex = source
    .replace(/\[\[([^\]]*)\]\]/g, (_, unit: string) => `\\,\\mathrm{${unit.replace(/Ω/g, "\\Omega ").replace(/µ|μ/g, "\\mu ")}}`)
    .replace(/([A-Za-z])__([A-Za-z0-9]+)/g, "$1_{$2}")
    .replace(/:=/g, "\\coloneqq ");
  try {
    katex.render(tex, element, { throwOnError: false, displayMode: display, output: "html" });
  } catch {
    element.textContent = source;
  }
}
