# md2pdf: Markdown to PDF through pandoc, with DNF's tuned page layouts.
#
# Settings come from the Nix wrapper (`runtimeEnv`): MD2PDF_ENGINE,
# MD2PDF_AUTHOR, MD2PDF_METADATA, MD2PDF_LINKS_FILTER, MD2PDF_RAWTEX_FILTER,
# MD2PDF_TYPST_TEMPLATE, MD2PDF_CONTEXT_HEADER.

usage() {
  cat <<EOF
Usage: md2pdf [OPTION]... FILE...

Convert Markdown files to PDF, next to each source (notes.md -> notes.pdf).

  -b, --big            larger text: 12pt on A4, 11pt on tablet
  -t, --tablet         A6 page, 9pt: zoomed to fit, large text on a tablet
  -e, --engine ENGINE  context or typst (default: $MD2PDF_ENGINE)
  -a, --author NAME    PDF Creator field (default: $MD2PDF_AUTHOR)
  -o, --output FILE    output path, single input only
  -h, --help           show this help
EOF
}

big=0
tablet=0
engine="$MD2PDF_ENGINE"
author="$MD2PDF_AUTHOR"
output=""
inputs=()

while [ $# -gt 0 ]; do
  case "$1" in
    -b | --big) big=1 ;;
    -t | --tablet) tablet=1 ;;
    -e | --engine)
      engine="${2:?--engine needs a value}"
      shift
      ;;
    -a | --author)
      author="${2:?--author needs a value}"
      shift
      ;;
    -o | --output)
      output="${2:?--output needs a value}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      inputs+=("$@")
      break
      ;;
    -*)
      echo "md2pdf: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
    *) inputs+=("$1") ;;
  esac
  shift
done

if [ ${#inputs[@]} -eq 0 ]; then
  usage >&2
  exit 2
fi
if [ -n "$output" ] && [ ${#inputs[@]} -gt 1 ]; then
  echo "md2pdf: --output takes a single input" >&2
  exit 2
fi

# ConTeXt page geometry; md2pdf.typ holds the typst margins of each paper.
if [ "$tablet" = 1 ]; then
  paper=a6
  size="$((big ? 11 : 9))pt"
  layout="backspace=10mm,width=85mm,topspace=10mm,header=0mm,footer=8mm,height=132mm"
else
  paper=a4
  size="$((big ? 12 : 10))pt"
  layout="backspace=20mm,width=170mm,topspace=20mm,header=0mm,footer=10mm,height=260mm"
fi

# Language and fonts come as a metadata file: a document's own YAML block
# still overrides them.
args=(
  --from=markdown
  --metadata-file="$MD2PDF_METADATA"
  --lua-filter="$MD2PDF_LINKS_FILTER"
  -V "papersize=$paper"
  -V "fontsize=$size"
)

case "$engine" in
  context)
    if ! command -v context >/dev/null; then
      echo "md2pdf: ConTeXt is not installed (darkone.home.office.enablePandocContext)" >&2
      exit 1
    fi
    args+=(
      --pdf-engine=context
      --include-in-header="$MD2PDF_CONTEXT_HEADER"
      -V "layout=$layout"
      -V "pagenumbering=location={footer,middle},left=- ,right= -"
      -V linkcolor=blue
      -V interlinespace=3ex
    )
    ;;
  typst)
    args+=(

      # `-citations`: `@name` stays text, as with ConTeXt; a native typst
      # `#cite` fails the build when the document has no bibliography.
      --to=typst-citations
      --pdf-engine=typst
      --lua-filter="$MD2PDF_RAWTEX_FILTER"

      # The template is imported by absolute path: typst reads nothing
      # outside its root, which defaults to the working directory.
      --pdf-engine-opt=--root=/
      -V "template=$MD2PDF_TYPST_TEMPLATE"
      -V "page-numbering=- 1 -"
    )
    ;;
  *)
    echo "md2pdf: unknown engine '$engine' (context or typst)" >&2
    exit 2
    ;;
esac

# Runs from the source directory, where relative image paths resolve.
convert() {
  local input="$1" target="$2"
  (cd -- "$(dirname -- "$input")" && pandoc "${args[@]}" -o "$target" "$(basename -- "$input")") || return 1
  exiftool -q -overwrite_original -Creator="$author" "$target" || return 1
}

status=0
for input in "${inputs[@]}"; do
  if [ ! -f "$input" ]; then
    echo "md2pdf: $input: no such file" >&2
    status=1
    continue
  fi

  target="$output"
  if [ -z "$target" ]; then
    case "$(basename -- "$input")" in
      *.*) target="${input%.*}.pdf" ;;
      *) target="$input.pdf" ;;
    esac
  fi
  target="$(realpath -m -- "$target")"
  if [ "$target" = "$(realpath -- "$input")" ]; then
    echo "md2pdf: $input: output would overwrite the source" >&2
    status=1
    continue
  fi

  if convert "$input" "$target"; then
    echo "$target"
  else
    echo "md2pdf: $input: conversion failed" >&2
    status=1
  fi
done

exit "$status"
