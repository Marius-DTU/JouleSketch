import Foundation

// MARK: - User guide

/// Where the guide is read. The steps differ a little: a mouse clicks and
/// a finger taps, and ⌘ is Ctrl on Windows.
enum GuidePlatform: String {
    case mac
    case touch
    case web
}

/// A piece of a guide section. Text may mark words as **bold**.
enum GuideBlock {
    case text(String)
    case bullets([String])
    /// A key (or gesture) and what it does.
    case keys([(key: String, action: String)])
    /// A highlighted hint.
    case tip(String)
}

struct GuideSection: Identifiable {
    let id: String
    let title: String
    let blocks: [GuideBlock]
}

/// The guide opened from the menu (Mac/iPad) or the toolbar (web), shared by the Mac/iPad app and the web
/// version so both explain the program the same way. The shortcuts shown
/// are the user's own key bindings.
enum UserGuide {
    static func sections(for platform: GuidePlatform, keys: KeyBindings) -> [GuideSection] {
        Words(platform: platform, bindings: keys).sections
    }

    /// Splits text into plain and **bold** runs, for drawing it.
    static func runs(_ text: String) -> [(text: String, bold: Bool)] {
        text.components(separatedBy: "**").enumerated()
            .filter { !$0.element.isEmpty }
            .map { ($0.element, $0.offset % 2 == 1) }
    }
}

/// The guide's text for one platform.
private struct Words {
    let platform: GuidePlatform
    let bindings: KeyBindings

    var isTouch: Bool { platform == .touch }
    var isWeb: Bool { platform == .web }

    /// "Klik" or "Tryk", and the lowercase forms.
    var Click: String { isTouch ? "Tryk" : "Klik" }
    var click: String { isTouch ? "tryk" : "klik" }
    var clicks: String { isTouch ? "trykker" : "klikker" }
    var doubleClick: String { isTouch ? "tryk to gange" : "dobbeltklik" }
    /// The ⌘ key, or Ctrl on Windows.
    var cmd: String { isWeb ? "Ctrl" : "⌘" }
    var cmdPlus: String { isWeb ? "Ctrl+" : "⌘" }
    var deleteKey: String { isWeb ? "Delete" : "⌫ (Backspace)" }

    /// The key bound to an action, e.g. "W", or "–" if it has none.
    func key(_ action: KeyAction) -> String {
        let key = bindings[action].uppercased()
        guard !key.isEmpty else { return "–" }
        return action.usesCommand
            ? (isWeb ? "Ctrl+" + (action.usesShift ? "Shift+" : "") + key : action.modifierSymbols + key)
            : key
    }

    /// "(W)" after a tool's name, left out on touch screens without keys.
    func shortcut(_ action: KeyAction) -> String {
        isTouch ? "" : " (\(key(action)))"
    }

    /// How to edit a symbol's values.
    var openEditor: String {
        switch platform {
        case .mac: "dobbeltklik eller højreklik på symbolet, eller markér det og åbn **Egenskaber** (sidepanelet) i værktøjslinjen"
        case .touch: "tryk to gange på symbolet, eller markér det og åbn **Egenskaber** (sidepanelet) i værktøjslinjen"
        case .web: "dobbeltklik eller højreklik på symbolet"
        }
    }

    var sections: [GuideSection] {
        [
            welcome, quickStart, sheet, palette, components, wires, values, ground,
            measuring, calculation, walkthrough, textBoxes, groups, editing,
            drawing, files, settings, shortcuts, troubleshooting,
        ]
    }

    // MARK: Sections

    var welcome: GuideSection {
        GuideSection(id: "welcome", title: "Velkommen til JouleSketch", blocks: [
            .text("JouleSketch er et program til at tegne og regne elektriske kredsløb. Du tegner diagrammet på et ark med gitter, skriver de værdier på, du kender, og så finder programmet resten: **spændinger, strømme, effekter og manglende komponentværdier**."),
            .text("Programmet kan også vise udregningen **trin for trin** (knudepunkts-, maske- og superpositionsmetoden) og lave **Maple-kode**, som du kan sætte direkte ind i en afleveringsopgave."),
            .tip(isWeb ? "Du kan altid åbne denne guide igen med **ⓘ** øverst til højre, ved siden af Indstillinger." : "Du kan altid åbne denne guide igen under **Sådan bruger du JouleSketch** i menuen ⋯ Visning."),
        ])
    }

    var quickStart: GuideSection {
        GuideSection(id: "quickStart", title: "Kom i gang på 5 minutter", blocks: [
            .text("Prøv at tegne en simpel spændingsdeler: en spændingskilde på 12 V og to modstande i serie."),
            .bullets([
                "**1. Spændingskilde:** vælg Kilder → Spændingskilde\(shortcut(.voltageSource)) i paletten\(isWeb ? "" : " nederst"), og \(click) på arket for at placere den. Du kan også trække fra − til +, så får den retning og længde med det samme.",
                "**2. Modstande:** vælg Modstand\(shortcut(.resistor)) og placér to modstande ved siden af kilden.",
                "**3. Ledninger:** vælg Ledning\(shortcut(.wire)), \(click) på et forbindelsespunkt for at starte, \(click) for hvert knæk, og \(click) på et andet forbindelsespunkt for at slutte ledningen.",
                "**4. Stel:** vælg Stel\(shortcut(.ground)) og sæt det på kildens − side. Det punkt er 0 V.",
                "**5. Værdier:** skift til Vælg\(shortcut(.select)), og \(openEditor). Skriv fx 12 i kilden og 1k og 2,2k i modstandene.",
                "**6. Mål:** vælg Spændingspunkt\(shortcut(.probe)) og \(click) på ledningen mellem modstandene. Spændingen vises straks med grå kursiv.",
            ]),
            .tip("Grå kursiv betyder **beregnet**. Almindelig skrift betyder en værdi, du selv har skrevet. Felter, du lader stå tomme, er ukendte, og dem prøver programmet at finde."),
        ])
    }

    var sheet: GuideSection {
        let moving: [(key: String, action: String)] = switch platform {
        case .mac: [
            ("To fingre på pegefeltet", "Flyt visningen"),
            ("Knib på pegefeltet", "Zoom ind og ud"),
            ("Højretræk", "Flyt visningen"),
            ("⌘+ / ⌘− / ⌘0", "Zoom ind, zoom ud, nulstil visningen (også i menuen ⋯ Visning)"),
        ]
        case .touch: [
            ("Træk med to fingre", "Flyt visningen"),
            ("Knib med to fingre", "Zoom ind og ud"),
            ("⋯ Visning", "Zoom ind, zoom ud og nulstil visningen"),
        ]
        case .web: [
            ("Rul (to fingre på pegefeltet)", "Flyt visningen"),
            ("Ctrl + rul / knib", "Zoom ind og ud"),
            ("Højretræk eller midterknap", "Flyt visningen"),
            ("− / 100 % / +", "Knapperne i værktøjslinjen: zoom ud, nulstil visningen, zoom ind"),
        ]
        }
        return GuideSection(id: "sheet", title: "Arket og visningen", blocks: [
            .text("Alt tegnes på et ark med gitterprikker. Komponenter, ledninger og punkter sætter sig altid fast på gitteret, så forbindelser rammer præcist."),
            .keys(moving),
            .text("Arkets størrelse, baggrund og om gitterprikkerne vises, kan ændres under **Indstillinger**."),
        ])
    }

    var palette: GuideSection {
        let menuMark = isWeb ? "en lille pil ▸" : "en lille trekant i hjørnet"
        var blocks: [GuideBlock] = [
            .text("Værktøjerne ligger i **paletten**\(isWeb ? " i venstre side" : " nederst på arket"). Værktøjer, der hører sammen, deler én knap. Knappen viser det værktøj, du sidst brugte i gruppen, og har \(menuMark)."),
            .bullets([
                "\(Click) på en knap for at vælge værktøjet, den viser.",
                "\(Click) **igen** på den valgte knap for at åbne menuen med resten af gruppen\(isTouch || isWeb ? "" : " (eller højreklik på knappen)").",
                isTouch ? "Uden tastatur skifter du værktøj i paletten." : "Hvert værktøj har en genvejstast, som står i menuen. Tasterne kan ændres under Indstillinger.",
            ]),
            .text("Grupperne er:"),
            .bullets([
                "**Vælg** – markér, flyt og redigér.",
                "**Ledninger, kontakter og knapper** – ledning, kontakt og trykknap.",
                "**Modstande, kondensatorer og spoler**.",
                "**Kilder** – spændingskilde, strømkilde, signalgenerator og de fire styrede kilder.",
                "**Dioder** – diode og lysdiode (LED).",
                "**Stel** (0 V).",
                "**Mål og beregn** – spændingspunkt, strøm i ledning, maskestrøm, effekt og samlet modstand (Req).",
                "**Noter** – tekstfelter og grupper.",
            ] + (isWeb ? ["**Tegning** – pen og viskelæder til fri tegning."] : [])),
        ]
        if !isWeb {
            blocks.append(.tip("Linjen lige over paletten fortæller altid, hvad du kan gøre med det valgte værktøj."))
        } else {
            blocks.append(.tip("Nogle værktøjer har ekstra valg øverst på arket, fx retningen for en maskestrøm eller pennens farve."))
        }
        return GuideSection(id: "palette", title: "Værktøjspaletten", blocks: blocks)
    }

    var components: GuideSection {
        GuideSection(id: "components", title: "Komponenter", blocks: [
            .text("En komponent placeres på to måder:"),
            .bullets([
                "**\(Click)** på arket for at sætte den med standardlængde.\(isTouch ? "" : " Tryk \(key(.rotate)) for at rotere den, før du placerer den.")",
                "**Træk** fra det ene punkt til det andet. Så får komponenten både placering, længde og retning med det samme.",
            ]),
            .text("Retningen betyder noget for nogle komponenter:"),
            .bullets([
                "**Spændingskilde\(shortcut(.voltageSource)) og signalgenerator\(shortcut(.signalGenerator)):** træk fra − til +.",
                "**Strømkilde\(shortcut(.currentSource)):** træk i strømmens retning.",
                "**Diode\(shortcut(.diode)) og lysdiode\(shortcut(.led)):** træk fra anode (+) til katode (−).",
                "**Modstand\(shortcut(.resistor)), kondensator\(shortcut(.capacitor)) og spole\(shortcut(.inductor)):** retningen er ligegyldig.",
            ]),
            .text("**Kontakt\(shortcut(.toggleSwitch)) og trykknap\(shortcut(.pushButton)):** \(click) på en kontakt med Vælg-værktøjet for at åbne eller lukke den. En trykknap er lukket, så længe du holder den nede, eller åben, hvis den er sat til normalt lukket (NC) i dens egenskaber. Beregningen følger med med det samme."),
            .text("**Styrede kilder** (spændingsstyret og strømstyret spændings- og strømkilde) har en forstærkning og en styring:"),
            .bullets([
                "En **spændingsstyret** kilde måler spændingen Vs mellem et + og et − punkt. Træk de to små markører hen på de punkter, der skal måles imellem.",
                "En **strømstyret** kilde måler strømmen Is gennem en ledning. Træk Is-markøren hen på ledningen.",
                "Forstærkningen skrives i kildens egenskaber, fx 2, 3 mA/V eller 5 V/mA.",
            ]),
            .tip("Komponenterne får automatisk navne som R1, R2, S1. Navnet kan ændres i symbolets egenskaber, og det bruges i gennemgangen og i Maple-koden."),
        ])
    }

    var wires: GuideSection {
        GuideSection(id: "wires", title: "Ledninger", blocks: [
            .text("Vælg Ledning\(shortcut(.wire)). En ledning kan tegnes på flere måder:"),
            .bullets([
                "**Punkt for punkt:** \(click) for at starte, \(click) for hvert støttepunkt (knæk), og \(click) på et forbindelsespunkt for at slutte. \(isTouch ? "Tryk på det samme punkt igen for at slutte et andet sted." : "Esc afslutter ledningen, hvor den er.")",
                "**Træk** fra punkt til punkt for en lige ledning.",
            ] + (isTouch ? [] : ["**⇧-træk** tegner en hel firkant af ledninger på én gang."])),
            .text("Ledninger, der mødes i et punkt eller ender på en anden ledning, er forbundet. Forbindelser med tre eller flere ledninger vises med en prik."),
            .text("Med Vælg-værktøjet markerer et \(click) på en ledning det stykke, du \(clicks) på (fra knæk til knæk). " + (isTouch
                ? "Knappen **Markér hele ledningen** i Egenskaber markerer hele ledningen med alle dens stykker."
                : "Tryk \(key(.selectWholeWire)) for at markere hele ledningen med alle dens stykker\(isWeb ? "" : ", eller brug knappen i Egenskaber").")),
        ])
    }

    var values: GuideSection {
        GuideSection(id: "values", title: "Værdier, navne og symboleditoren", blocks: [
            .text("For at skrive en værdi på en komponent, et spændingspunkt eller en strømpil skal du \(openEditor)."),
            .text("Værdier skrives med SI-præfiks, og enheden kan skrives med eller udelades. Både komma og punktum virker:"),
            .keys([
                ("4,7k eller 4.7 kΩ", "4 700 Ω"),
                ("10m", "0,01 (fx 10 mA eller 10 mV)"),
                ("2,2 µA eller 2.2u", "0,000 002 2 A"),
                ("100n", "100 nF"),
                ("3 mA/V", "Forstærkning 0,003 (styrede kilder)"),
            ]),
            .text("Præfikserne er p (piko), n (nano), µ eller u (mikro), m (milli), k (kilo), M (mega) og G (giga)."),
            .bullets([
                "**Tomt felt = ukendt.** Programmet prøver at finde de ukendte værdier ud fra dem, du kender.",
                "En **modstand** viser de nærmeste standardværdier fra E-rækkerne (IEC 60063) og deres farvekode.",
                "En **signalgenerator** har amplitude, frekvens, fase og bølgeform (sinus eller firkant med duty cycle).",
                "En **diode** eller **lysdiode** har en fast spænding, når den leder (0,7 V og 2 V som standard).",
                "Hvert symbol kan få en **note**, som vises på tegningen.",
            ]),
        ])
    }

    var ground: GuideSection {
        GuideSection(id: "ground", title: "Stel (0 V)", blocks: [
            .text("Vælg Stel\(shortcut(.ground)) og \(click) på et punkt i kredsløbet. Det punkt er referencen på **0 V**, og alle spændingspunkter måles i forhold til det.\(isTouch ? "" : " \(key(.rotate)) roterer symbolet.")"),
            .tip("Uden stel kan spændingerne i punkterne ikke beregnes. Beregningsrapporten siger til, hvis det mangler."),
        ])
    }

    var measuring: GuideSection {
        GuideSection(id: "measuring", title: "Mål og beregn", blocks: [
            .text("Værktøjerne i gruppen **Mål og beregn** viser, hvad der sker i kredsløbet. Hver af dem kan også have en kendt værdi, som programmet så regner videre ud fra."),
            .bullets([
                "**Spændingspunkt\(shortcut(.probe)):** \(click) på en ledning. Punktet får et navn (VA, VB …) og viser spændingen i forhold til stel.",
                "**Spændingsfald:** \(isWeb ? "slå Spændingsfald (+ og −) til øverst på arket, eller hold Ctrl og træk fra et punkt" : isTouch ? "hold ⌘ på et tilsluttet tastatur" : "⌘-klik på spændingspunkt-værktøjet, eller hold ⌘ og træk fra et punkt"), og træk så fra + til −. Det viser spændingen mellem to vilkårlige punkter.",
                "**Strøm i ledning\(shortcut(.current)):** \(click) på en ledning for at sætte en strømpil. Træk langs ledningen for at vælge retningen\(isTouch ? "" : ", eller tryk \(key(.rotate)) for at vende den").",
                "**Maskestrøm\(shortcut(.mesh)):** \(click) inde i en maske. Pilen viser maskestrømmen med eller mod uret\(isTouch ? "" : " – \(key(.rotate)) vender retningen"). Navn og retning bruges af maskestrømsmetoden.",
                "**Effekt\(shortcut(.power)):** træk en cirkel om en eller flere komponenter for at se den samlede afsatte effekt. \(Click) på en enkelt komponent slår dens effektcirkel til og fra.",
                "**Samlet modstand, Req\(shortcut(.equivalent)):** \(click) på det første punkt (A) og så det andet (B). Req er modstanden set mellem de to punkter, med spændingskilder kortsluttet og strømkilder afbrudt.",
            ]),
        ])
    }

    var calculation: GuideSection {
        let report = isWeb ? "**Beregning** i værktøjslinjen (tallet i parentes er antallet af ting, der skal tjekkes)" : "knappen **Beregning – hvad mangler?** i værktøjslinjen (et flueben, når alt er beregnet)"
        return GuideSection(id: "calculation", title: "Beregningen", blocks: [
            .text("Kredsløbet regnes hele tiden, mens du tegner. Beregnede værdier vises med **grå kursiv** på tegningen."),
            .text("Åbn \(report) for at se, hvor mange ukendte værdier der er fundet, hvad der mangler, og om nogle af de kendte værdier modsiger hinanden."),
            .text("**DC og AC:**"),
            .bullets([
                "Uden signalgenerator regnes der **DC**: en kondensator er en afbrydelse, og en spole er en kortslutning.",
                "Med en **signalgenerator** regnes der med fasorer: kondensatorer og spoler får deres impedans, og spændinger og strømme vises som amplitude ∠ fase.",
                "En **firkant** (PWM) regnes som middelværdi (D · højspænding) og grundtone, så du kan se, hvor meget der er tilbage af signalet efter fx et RC-filter.",
                "En firkant sat til 0 V er en **low-side udgang (LSO)**: åben i duty cyclen og trukket til stel resten af perioden.",
                "**Dioder** regnes med en fast spænding, og programmet finder selv ud af, om de leder eller spærrer.",
            ]),
            .text("**Study mode** skjuler de beregnede værdier, så du kan regne selv først, men stadig kan se, om alt kan beregnes. \(isWeb ? "Slå den til under Indstillinger (⚙)." : "Slå den til med kontakten i værktøjslinjen eller i menuen ⋯ Visning.")"),
        ])
    }

    var walkthrough: GuideSection {
        let open = isWeb ? "Klik på **Gennemgang og Maple** i værktøjslinjen" : "\(Click) på **Maple-output** (ƒ) i værktøjslinjen. Knappen virker, når alle ukendte værdier kan beregnes"
        return GuideSection(id: "walkthrough", title: "Gennemgang og Maple", blocks: [
            .text("\(open). Her ser du udregningen trin for trin med formler, som du kan følge eller bruge som facit."),
            .bullets([
                "**Knudepunkt** – Kirchhoffs strømlov i hvert knudepunkt med strømmene skrevet med Ohms lov.",
                "**Maske** – Kirchhoffs spændingslov rundt i hver maske. Kræver et plant diagram (ingen ledninger, der krydser).",
                "**Superposition** – hver kilde regnes for sig, og bidragene lægges sammen.",
            ]),
            .text("Under gennemgangen står **Maple-koden**: kendte værdier med enheder, navngivne ligninger og de resultater, du har bedt om (med spændingspunkter, strømpile, effekter osv.)."),
            .bullets([
                "**Kopiér til Maple (2-D)** sætter beregningen ind i en Maple-worksheet som 2-D Math med sænkede navne og brøker.",
                "**Kopiér som tekst** giver almindelig Maple-kode.",
                "Har tegningen **grupper**, kan du vælge en gruppe og kun få gennemgang og kode for den.",
                "Gennemgangen kan vises **i et vindue** eller **side om side** med tegningen, så den følger med, mens du retter.",
            ]),
        ])
    }

    var textBoxes: GuideSection {
        GuideSection(id: "textBoxes", title: "Tekstfelter og udregninger", blocks: [
            .text("Vælg Tekst og udregning\(shortcut(.text)) og \(click) på arket for at indsætte et tekstfelt. \(Click) på et eksisterende tekstfelt (eller \(doubleClick) med Vælg) for at skrive i det."),
            .text("Hver linje kan være almindelig tekst eller matematik i LaTeX:"),
            .keys([
                (key(.textMode), "Linjen er tekst"),
                (key(.mathMode), "Linjen er matematik (LaTeX), fx \\frac{U}{R}"),
                (key(.evaluateMath), "Udregn formlen på linjen"),
                (key(.unitBrackets), "Indsæt en enhed [[ ]], så der regnes med enheder"),
            ]),
            .bullets([
                "Formler kan bruge navnene fra tegningen, fx R_1 eller V_A, og regner med deres værdier – også de beregnede.",
                "**navn := formel** giver et navn en værdi, som de næste linjer kan bruge, fx R_{eq} := R_1 + R_2.",
                "**!navn := formel** gælder hele dokumentet og sætter værdien på symbolet med det navn på tegningen, fx !R1 := 470[[Ω]] + 1[[kΩ]]. Værdien følger med, når du retter formlen.",
                "Med enheder i [[ ]] kan du fx skrive 12[[V]]/470[[Ω]] og få resultatet i mA.",
            ]),
        ])
    }

    var groups: GuideSection {
        GuideSection(id: "groups", title: "Grupper og udeladte områder", blocks: [
            .text("**Gruppe\(shortcut(.groupArea)):** træk en boks om en del af tegningen. Gruppen får et navn og en farve, og i gennemgangen kan du vælge den og få output kun for det, der ligger helt inden for boksen. Det er praktisk, når et ark har flere opgaver. \(isTouch ? "Tryk to gange" : "Dobbeltklik") på navnet for at omdøbe gruppen."),
            .text(isTouch
                ? "**Udeladt område:** et område, hvor indholdet er udeladt af beregningen og Maple-koden. Det tegnes i Mac- eller web-versionen med ⌘/Ctrl + højretræk; på iPad kan det flyttes og slettes."
                : "**Udeladt område:** hold \(cmd) og træk med højre museknap. Det, der ligger helt inden for firkanten, er udeladt af beregningen og Maple-koden – fx en skitse eller en gammel version af kredsløbet. Slet firkanten for at tage indholdet med igen."),
        ])
    }

    var editing: GuideSection {
        var keys: [(key: String, action: String)] = [
            (Click, "Vælg et element"),
        ]
        if !isTouch { keys.append(("\(cmd)-klik", "Tilføj til eller fjern fra markeringen")) }
        keys += [
            ("Træk på en tom plads", "Markér alt inden for et område"),
            ("Træk i et markeret element", "Flyt det (resten af kredsløbet følger med)"),
            (isTouch ? "Tryk to gange" : "Dobbeltklik / højreklik", "Redigér symbolets værdier"),
        ]
        if !isTouch {
            keys += [
                (key(.rotate), "Rotér det markerede, eller vend en strømpil eller maskestrøm"),
                (key(.selectWholeWire), "Markér hele ledningen"),
                (deleteKey, "Slet det markerede"),
                ("\(cmdPlus)A", "Markér alt"),
                ("\(cmdPlus)C / \(cmdPlus)V", "Kopiér, og indsæt ved markøren"),
                ("\(cmdPlus)Z", "Fortryd"),
                (isWeb ? "Ctrl+Y / Ctrl+Shift+Z" : "⇧⌘Z", "Gentag"),
                ("Esc", "Afslut det, du er i gang med, eller skift til Vælg"),
            ]
        }
        return GuideSection(id: "editing", title: "Markér, flyt og redigér", blocks: [
            .text("Brug Vælg\(shortcut(.select)) til at arbejde med det, der allerede er tegnet."),
            .keys(keys),
            .text(isWeb
                ? "Fortryd, gentag, rotér og slet findes også som knapper i værktøjslinjen."
                : "Fortryd, gentag og slet findes også i værktøjslinjen, og **Egenskaber** (sidepanelet) viser og redigerer det markerede."),
        ])
    }

    var drawing: GuideSection {
        GuideSection(id: "drawing", title: "Fri tegning", blocks: [
            .text(isWeb
                ? "Vælg **Pen** i gruppen Tegning for at tegne frit på arket, fx for at markere noget eller skrive en note i hånden. Vælg farve og tykkelse øverst på arket. **Viskelæderet** sletter igen."
                : "Slå **Tegn** (blyanten) til i værktøjslinjen for at tegne frit på arket\(isTouch ? " – også med Apple Pencil" : ""). Paletten skifter til pennens farver og tykkelser og et viskelæder. Hold ⌘ med viskelæderet for at slette hele streger. Slå Tegn fra igen for at komme tilbage til værktøjerne."),
            .text("Streger er kun til noter og har ingen betydning for beregningen."),
        ])
    }

    var files: GuideSection {
        let blocks: [GuideBlock] = switch platform {
        case .mac, .touch: [
            .text("Kredsløb gemmes som **.joulesketch**-filer, som både Mac/iPad og web-versionen kan åbne. Ændringer gemmes automatisk."),
            .bullets([
                "Opret et nyt kredsløb med **Arkiv → Nyt kredsløb**\(isTouch ? " eller fra dokumentoversigten" : " (⌘N)").",
                platform == .mac ? "Hver fil åbner i sin egen fane i samme vindue." : "Åbn filer fra dokumentoversigten eller appen Filer.",
                "**Ryd tegning** i menuen ⋯ Visning sletter alt på arket (kan fortrydes).",
            ]),
        ]
        case .web: [
            .text("Kredsløb gemmes som **.joulesketch**-filer, som både web-versionen og Mac/iPad-appen kan åbne."),
            .keys([
                ("Ny", "Start et nyt, tomt kredsløb"),
                ("Åbn… (Ctrl+O)", "Åbn en .joulesketch-fil"),
                ("Gem (Ctrl+S)", "Gem kredsløbet som fil"),
            ]),
            .text("Web-versionen gemmer også løbende i browseren, så intet forsvinder, hvis siden lukkes. En prik efter filnavnet betyder, at der er ændringer, som ikke er gemt i en fil."),
        ]
        }
        return GuideSection(id: "files", title: "Filer", blocks: blocks)
    }

    var settings: GuideSection {
        let open = switch platform {
        case .mac: "Åbn **Indstillinger** i menuen ⋯ Visning eller med ⌘,."
        case .touch: "Åbn **Indstillinger** i menuen ⋯ Visning."
        case .web: "Åbn **Indstillinger** med ⚙ øverst til højre."
        }
        return GuideSection(id: "settings", title: "Indstillinger", blocks: [
            .text(open),
            .bullets([
                isWeb
                    ? "**Udseende:** gitterprikker og arkets størrelse i gitterpunkter."
                    : "**Udseende:** baggrund (fx papir eller en egen farve), gitterprikker og arkets størrelse i gitterpunkter.",
                "**Symboler:** modstande som europæisk rektangel (IEC) eller amerikansk zigzag (ANSI).",
                "**Tastaturgenveje:** alle værktøjsgenveje kan ændres. Taster, der bruges to steder, bliver markeret.",
            ] + (isWeb ? ["**Study mode:** skjul de beregnede værdier."] : [])),
        ])
    }

    var shortcuts: GuideSection {
        let tools = KeyAction.allCases.filter { !$0.usesCommand }
        var blocks: [GuideBlock] = [
            .text(isTouch
                ? "Med et tastatur tilsluttet virker de samme genveje som på Mac. Dine nuværende genveje er:"
                : "Dine nuværende genveje (de kan ændres under Indstillinger). De virker, når arket er aktivt:"),
            .keys(tools.map { (key($0), $0.displayName) }),
            .text("I et tekstfelt:"),
            .keys(KeyAction.allCases.filter(\.usesCommand).map { (key($0), $0.displayName) }),
        ]
        if isWeb {
            blocks.append(.tip("På Windows bruges Ctrl, hvor Mac-versionen bruger ⌘."))
        }
        return GuideSection(id: "shortcuts", title: "Genvejstaster", blocks: blocks)
    }

    var troubleshooting: GuideSection {
        GuideSection(id: "troubleshooting", title: "Tips og fejlfinding", blocks: [
            .bullets([
                "**En værdi bliver ikke beregnet:** åbn Beregning og se, hvad der mangler. Ofte mangler der et stel, eller der er for få kendte værdier.",
                "**\"Værdierne modsiger hinanden\":** du har skrevet flere værdier, end kredsløbet tillader (fx både spænding, strøm og modstand, der ikke passer med Ohms lov). Slet en af dem, så programmet selv finder den.",
                "**\(isWeb ? "Gennemgangen" : "Maple-output") er ikke klar:** alle ukendte værdier på arket skal kunne beregnes først. Læg ting, du ikke vil regne på, i et udeladt område.",
                "**Maskemetoden kan ikke bruges:** diagrammet skal være plant – flyt ledninger, så ingen krydser hinanden.",
                "**En ledning hænger ikke sammen:** ledninger forbindes kun i deres endepunkter og knæk. Tjek at enderne rammer et forbindelsespunkt.",
                "**Fortrudt for meget?** Gentag\(isTouch ? "" : " (\(isWeb ? "Ctrl+Y" : "⇧⌘Z"))") henter det igen.",
            ]),
        ])
    }
}
