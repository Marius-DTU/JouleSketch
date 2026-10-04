<p align="center">
  <img src="docs/logo.png" alt="JouleSketch-logo" width="160">
</p>

<h1 align="center">JouleSketch</h1>

JouleSketch er et program til at tegne og regne elektriske kredsløb. Man tegner
diagrammet på et ark med gitter, skriver de kendte værdier på, og så finder
programmet resten: spændinger, strømme, effekter og manglende
komponentværdier. Det kan også vise udregningen trin for trin og lave
Maple-kode, man kan sætte ind i en afleveringsopgave.

Der er to versioner, som bygger på den samme kode:

| Version | Platform | Hvor |
|---|---|---|
| App | Mac (macOS 15+) og iPad (iPadOS 18+) | `JouleSketch.xcodeproj` (SwiftUI) |
| Web | Windows og alle andre computere, i browseren | `Web/` (Swift → WebAssembly) |

## Funktioner

### Tegning
- **Komponenter:** modstand, kondensator, spole, spændingskilde, strømkilde,
  signalgenerator, kontakt, trykknap, diode, lysdiode (LED) og de fire styrede kilder (spændingsstyret og strømstyret spændings- og
  strømkilde).
- **Ledninger** med støttepunkter. Komponenter kan placeres med et klik eller
  trækkes ud mellem to punkter, så retning og placering kommer med med det
  samme.
- **Kontakter og trykknapper:** klik på en kontakt med Vælg-værktøjet for at
  åbne eller lukke den; en trykknap er lukket, mens man holder den nede
  (eller åben, hvis den er sat til normalt lukket, NC).
  Beregningen følger med med det samme.
- **Stel** (0 V), **strømpile** på ledninger, **spændingspunkter** og
  **spændingsfald** mellem to punkter.
- **Maskestrømme**, der vises inde i en maske, med eller mod uret.
- **Effektcirkler** om en eller flere komponenter, som viser den afsatte
  effekt.
- **Samlet modstand** (Req) mellem to valgfrie punkter.
- **Tekstfelter** med almindelig tekst eller matematik i LaTeX, som også kan
  udregnes med enheder.
- **Grupper**, der deler et større kredsløb op i dele i Maple-vinduet.
- Fortryd, kopiér/indsæt, flyt, rotér og markér hele ledninger.
- **Symboleditor** (dobbeltklik eller højreklik på et symbol) til komponenternes værdier, og farvekoder for modstande
  (E-rækkerne efter IEC 60063).

### Beregning
- Løser kredsløbet ud fra de kendte værdier og finder ukendte spændinger,
  strømme, effekter og komponentværdier.
- Med en **signalgenerator** (amplitude, frekvens og fase) regnes kredsløbet
  med fasorer: kondensatorer og spoler får deres impedans, og spændinger og
  strømme vises som amplitude ∠ fase. Uden en signalgenerator regnes der DC,
  hvor en kondensator er en afbrydelse og en spole en kortslutning.
- Signalgeneratoren har en **bølgeform**: sinus eller firkant (PWM med duty
  cycle). Andet end en sinus regnes som middelværdi (fx D · højspænding) og
  grundtone (første Fourier-led, for en firkant (2A/π)·sin(πD)) med fasorer,
  så man kan se, hvor meget der er tilbage af signalet efter fx et RC-filter.
  En firkant sat til 0 V er en **low-side udgang (LSO)**: åben (høj) i duty
  cyclen og trukket til stel resten af perioden, trukket op af resten af
  kredsløbet (fx en pull-up-modstand).
- Dioder og lysdioder regnes med en fast spænding (0,7 V og 2 V som
  standard), og programmet finder selv ud af, om de leder eller spærrer.
- En **beregningsrapport** fortæller, hvad der mangler, og om de kendte
  værdier modsiger hinanden.
- **Study mode** skjuler resultaterne, så man kan regne selv først og stadig
  se, om alt kan beregnes.

### Gennemgange
Trin-for-trin-udregninger med formler, som man kan følge eller bruge som facit:
- **Knudepunktsmetoden** – Kirchhoffs strømlov i hvert knudepunkt med
  strømmene skrevet med Ohms lov.
- **Maskestrømsmetoden** – Kirchhoffs spændingslov rundt i hver maske
  (kræver et plant diagram).

### Maple-eksport
Kredsløbet skrives som Maple-kode efter knudepunktsmetoden: kendte værdier
med enheder, navngivne ligninger, der fungerer som dokumentation i en
opgave, og kun de resultater, man har bedt om, omregnet til fornuftige
enheder. Koden kan kopieres som tekst eller som MathML.

```
with(Units):
unassign(anames(user)):
R1 := 50*Unit('ohm'):
S1 := 12*Unit('V'):
VA := S1:
L1 := (VA - VB)/R2 - I1 = 0:
sol := solve({L1, L2}, {R2, VB}):
assign(sol):
VB := evalf(convert(VB, 'units', 'V'), 4);
```

### Filer
Kredsløb gemmes som `.joulesketch`-filer, som begge versioner kan åbne og
gemme. På Mac åbner hver fil i sin egen fane. Web-versionen gemmer også
løbende i browseren, så intet forsvinder, hvis siden lukkes.

## Genvejstaster

Alle genveje kan ændres under **Indstillinger**. Standard er:

| Tast | Værktøj | Tast | Værktøj |
|---|---|---|---|
| `S` | Vælg | `I` | Strømpil |
| `W` | Ledning | `P` | Spændingspunkt |
| `1` | Modstand | `F` | Effekt |
| `2` | Spændingskilde | `E` | Samlet modstand (Req) |
| `3` | Strømkilde | `M` | Maskestrøm |
| `4` | Diode | `T` | Tekstfelt |
| `5` | Lysdiode | `K` | Gruppe |
| `C` | Kondensator | `L` | Spole |
| `6` | Signalgenerator | `X` | Kontakt |
| `B` | Trykknap | | |
| `G` | Stel | `R` | Rotér / vend retning |
| `U` | Markér hele ledningen | `Esc` | Afslut / tilbage til Vælg |

I et tekstfelt: `⌘T` tekst, `⌘M` matematik (LaTeX), `⌘B` udregn og `⌘U`
indsæt en enhed `[[ ]]`.

## Kom i gang

### Mac og iPad
Åbn `JouleSketch.xcodeproj` i Xcode og kør skemaet **JouleSketch**.

### Web
Se [`Web/README.md`](Web/README.md) for værktøjer og byggevejledning. Kort
fortalt:

```sh
Web/build.sh dev                 # testside på http://localhost:5173
Web/build.sh                     # færdig side i Web/app/dist
docker compose up -d --build     # eller i Docker: http://localhost:8080
```

## Opbygning

Logikken ligger i delte Swift-filer i `JouleSketch/`, som både Mac-appen og
web-versionen bruger. Web-versionen oversætter dem til WebAssembly (listen
står i `Package.swift`), så en rettelse i dem kommer med i begge.

| Del | Filer |
|---|---|
| Kredsløb og filformat | `Circuit.swift` |
| Beregning | `CircuitSolver.swift` |
| Gennemgange | `Walkthrough.swift`, `NodalWalkthrough.swift`, `MeshWalkthrough.swift` |
| Maple og LaTeX | `MapleExporter.swift`, `MapleMathML.swift`, `MathLatex.swift` |
| Redigering og klik på arket | `CircuitEditor.swift`, `SheetInteraction.swift` |
| Tegning af skemaet | `SchematicScene.swift` |
| Genvejstaster | `KeyBindings.swift` |
| Mac/iPad-brugerflade | de øvrige filer i `JouleSketch/` (SwiftUI) |
| Web-brugerflade og bro | `Web/app/src/`, `Web/Bridge/` |

De delte filer bruger kun `Foundation` (og `Observation`), ikke
SwiftUI/AppKit/UIKit. Mac-appen tegner stadig selv i `SchematicCanvas.swift`
og `SymbolRenderer.swift`, så ændringer i tegning og musebevægelser skal
laves begge steder, indtil Mac-appen også bruger `SchematicScene`.

## Udgivelse af web-versionen

Når der pushes til `main`, bygger GitHub Actions
(`.github/workflows/web.yml`) web-versionen som en container og lægger den på
`ghcr.io`. Serveren henter selv den nye version via Watchtower
(`deploy/docker-compose.yml`). Buildet starter kun, når kode eller byggefiler
ændres, ikke ved ændringer i dokumentation som denne fil.
