# JouleSketch til Windows (web-version)

Web-versionen kører i browseren (Edge, Chrome, Firefox) på Windows og alle
andre computere. Den bruger **de samme Swift-filer** som Mac-appen, så rettelser
i beregning, redigering, tegning og Maple-eksport kommer med i begge.

## Hvad deles, og hvad er kun web

| Del | Hvor | Delt med Mac? |
|---|---|---|
| Kredsløb, filformat, beregning, gennemgange, Maple | `JouleSketch/Circuit.swift`, `CircuitSolver.swift`, `*Walkthrough.swift`, `Maple*.swift`, `MathLatex.swift` | Ja |
| Redigering (placér, flyt, slet, fortryd, kopiér) | `JouleSketch/CircuitEditor.swift` | Ja |
| Klik og træk på arket | `JouleSketch/SheetInteraction.swift` | Ja (Mac bruger stadig `SchematicCanvas` – se nedenfor) |
| Hvordan skemaet tegnes | `JouleSketch/SchematicScene.swift` | Ja (Mac bruger stadig `SchematicCanvas` – se nedenfor) |
| Genvejstaster | `JouleSketch/KeyBindings.swift` | Ja |
| Bro mellem Swift og browseren | `Web/Bridge/` | Kun web |
| Knapper, vinduer, tekstbokse | `Web/app/src/` | Kun web |

Listen over delte filer står i `Package.swift`.

## Første gang: installér værktøjerne

Åbn Terminal og kør:

```sh
brew install node swiftly
swiftly init --assume-yes
source ~/.swiftly/env.sh
swiftly install 6.4.0 && swiftly use 6.4.0
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d
```

## Byg og prøv

```sh
Web/build.sh dev    # åbner en testside på http://localhost:5173
Web/build.sh        # bygger den færdige side i Web/app/dist
```

Mappen `Web/app/dist` kan lægges på en hvilken som helst webserver (fx GitHub
Pages eller Netlify). Brugerne åbner bare linket og får altid den nyeste
version.

## Docker

Hele web-versionen kan bygges og køres i en container, uden Xcode eller
andre værktøjer installeret:

```sh
docker compose up -d --build    # åbn http://localhost:8080
```

Efter en rettelse køres samme kommando igen. Den bygger den nye version og
skifter over til den.

## Automatisk opdatering via GitHub

1. Når der pushes til `main`, bygger GitHub containeren
   (`.github/workflows/web.yml`) og lægger den på `ghcr.io`. Det tager ca. 15
   minutter, og det kan følges under fanen **Actions** på GitHub.
2. På serveren kører `deploy/docker-compose.yml`. Watchtower kigger efter en ny
   version hvert 5. minut og skifter selv over til den.

Første gang på serveren:

1. Lav en adgangsnøgle på GitHub: **Settings → Developer settings → Personal
   access tokens → Tokens (classic) → Generate new token**. Kryds kun
   `read:packages` af.
2. Kopiér `deploy/docker-compose.yml` til serveren og kør:
   ```sh
   docker login ghcr.io -u Marius-DTU    # adgangskode: nøglen fra trin 1
   docker compose up -d
   ```

## Filer

Web-versionen åbner og gemmer de samme `.joulesketch`-filer som Mac-appen.
Det, man arbejder på, gemmes også automatisk i browseren, så det ikke
forsvinder, hvis siden lukkes.
