-- md2pdf: links to an anchor missing from the document become plain text.
-- ConTeXt drops them silently, typst refuses to compile (`label does not
-- exist`).

local ids = {}

local function collect(el)
  if el.identifier and el.identifier ~= '' then
    ids[el.identifier] = true
  end
end

local function unlink(link)
  local anchor = link.target:match('^#(.+)$')
  if anchor and not ids[anchor] then
    return link.content
  end
end

-- Two passes: every identifier must be known before the first link is judged.
return {
  { Block = collect, Inline = collect },
  { Link = unlink },
}
