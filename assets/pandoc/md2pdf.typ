// md2pdf layout for the pandoc typst writer, imported through `-V template=`.
// Mirrors the ConTeXt output: Gentium body, regular-weight headings, blue
// links, `- n -` folio.

// `set document(author:)` takes strings; pandoc hands names over as content.
#let content-to-string(content) = {
  if content.has("text") {
    content.text
  } else if content.has("children") {
    content.children.map(content-to-string).join("")
  } else if content.has("body") {
    content-to-string(content.body)
  } else if content == [ ] {
    " "
  }
}

// Margins per paper, matching the ConTeXt `layout` in md2pdf.sh: pandoc can
// only hand `margin` over from a metadata map, never from `-V`.
#let margins = (
  a4: (x: 20mm, top: 20mm, bottom: 27mm),
  a6: (x: 10mm, top: 10mm, bottom: 14mm),
)

#let link-blue = rgb("#0000ff")

#let conf(
  title: none,
  subtitle: none,
  authors: (),
  keywords: (),
  date: none,
  abstract: none,
  cols: 1,
  margin: auto,
  paper: "a4",
  lang: "fr",
  region: "FR",
  font: ("Gentium",),
  fontsize: 10pt,
  sectionnumbering: none,
  pagenumbering: "- 1 -",
  doc,
) = {
  set document(
    title: title,
    author: authors.map(author => content-to-string(author.name)),
    keywords: keywords,
  )
  // The folio pattern (`- 1 -`) stays in the footer: as the page numbering it
  // would also dress the page numbers of the table of contents.
  set page(
    paper: paper,
    margin: if margin == auto { margins.at(paper, default: auto) } else { margin },
    numbering: if pagenumbering != none { "1" },
    footer: if pagenumbering != none {
      context align(center, counter(page).display(pagenumbering))
    },
    columns: cols,
  )

  // Table of contents as in ConTeXt: blue links, airy, spaced dot leaders.
  show outline.entry: set block(spacing: 0.9em)
  show outline.entry: set text(fill: link-blue)
  set outline.entry(fill: pad(x: 0.5em, repeat(gap: 0.5em)[.]))

  // Unnumbered captions, as in the ConTeXt output.
  set figure(numbering: none)

  // Gentium lacks arrows, symbols and box drawing: DejaVu Sans fills the gaps.
  set text(
    lang: lang,
    region: region,
    font: font + ("DejaVu Sans",),
    size: fontsize,
    top-edge: 0.8em,
    bottom-edge: -0.2em,
  )

  // 1em line box + 0.36em leading: the 3ex interline of the ConTeXt output;
  // paragraphs add a touch more than its `medium` whitespace (0.51em).
  set par(justify: true, leading: 0.36em, spacing: 0.95em)
  set heading(numbering: sectionnumbering)

  // Absolute sizes: an `em` here would compound with the built-in heading scale.
  show heading: set text(weight: "regular", size: fontsize)
  show heading: set block(above: 1.6em, below: 0.9em)
  show heading.where(level: 1): set text(size: fontsize * 1.728)
  show heading.where(level: 2): set text(size: fontsize * 1.44)
  show heading.where(level: 3): set text(weight: "bold")
  show link: set text(fill: link-blue)

  // pandoc draws `---` as a centred half-width line: thin, full width, airy.
  show line.where(start: (25%, 0%)): block(
    above: 1.5em,
    below: 1.5em,
    line(length: 100%, stroke: 0.4pt),
  )

  // Bodies 1.5em past the marker, whatever its width: the ConTeXt columns,
  // which set the levels apart.
  set list(indent: 0pt, body-indent: 0.9em, marker: ([•], [–]).map(m => box(width: 0.6em, m)))

  // Footnotes as in ConTeXt: blue number hung in the margin, every line of
  // the note on the text column.
  show footnote: set text(fill: link-blue)
  show footnote.entry: it => {
    let loc = it.note.location()
    let number = numbering(it.note.numbering, ..counter(footnote).at(loc))
    let mark = link(loc, super(text(fill: link-blue, number)) + h(0.25em))
    context par(h(-measure(mark).width) + mark + it.note.body)
  }

  // DejaVu Sans Mono box drawing spans 0.928em up, 0.236em down: with these
  // edges and no leading, schema strokes join from one line to the next.
  show raw: set text(font: ("DejaVu Sans Mono",), size: fontsize)
  show raw.where(block: true): set text(top-edge: 0.928em, bottom-edge: -0.236em)
  show raw.where(block: true): set par(leading: 0em, justify: false)

  // Inline code at 85%: DejaVu Sans Mono's x-height outgrows Gentium's.
  show raw.where(block: false): set text(size: fontsize * 0.85)

  // Schemas keep their shape: a block wider than the text is scaled down to
  // fit, where ConTeXt wraps its lines.
  show raw.where(block: true): it => layout(size => {
    let natural = measure(it).width
    if natural <= size.width {
      it
    } else {
      scale(size.width / natural * 100%, reflow: true, block(width: natural, it))
    }
  })

  // Long inline identifiers (file names, paths) may break after `_ / . -`
  // instead of overflowing the margin. Spaces keep the monospace advance
  // (0.6em) rather than stretch with the justified line, and still break.
  // An empty box is the break point: a zero-width space would end up in the
  // text copied from the PDF.
  show raw.where(block: false): it => {
    show regex("[_/.-]"): c => c + box()
    show " ": box(width: 0.6em) + box()
    it
  }

  // Tables as in ConTeXt: ragged left cells, compact, ruled top and bottom,
  // split across pages (a figure is unbreakable by default). pandoc wraps
  // each table in `align(center)`, which the cells inherit.
  show figure.where(kind: table): set block(breakable: true)
  set table(inset: (x: 4pt, y: 3pt))
  show table: set align(start)
  show table: set par(justify: false)
  show table: it => block(stroke: (y: 0.5pt), it)

  if title != none {
    align(center, block(below: 2em)[
      #text(size: 2.074em)[#title]
      #set text(size: 1.2em)
      #if subtitle != none {
        parbreak()
        subtitle
      }
      #if authors != () {
        parbreak()
        authors.map(author => author.name).join(", ")
      }
      #if date != none {
        parbreak()
        date
      }
    ])
  }

  if abstract != none {
    block(inset: (x: 2em), below: 2em)[#emph(abstract)]
  }

  doc
}
