-- md2pdf, typst engine only: a table whose columns all got the same width is
-- laid out like an HTML auto table instead.
--
-- pandoc turns the separator dashes into relative widths as soon as a row
-- runs long: `|---|---|` then gives a two-letter code as much room as a
-- sentence. Unequal dashes (`|--|--------|`) still size the columns by hand.
-- ConTeXt keeps pandoc's widths: its tables do not wrap unsized columns.

-- Mean Gentium advance, space included, measured on French text.
local CHAR_EM = 0.41

-- Horizontal cell inset of md2pdf.typ, both sides.
local INSET_PT = 10

local UNITS = { pt = 1, mm = 72 / 25.4, cm = 72 / 2.54, ['in'] = 72 }

local function to_pt(length, default)
  local amount, unit = tostring(length or ''):match('^([%d.]+)(%a+)$')
  return amount and UNITS[unit] and tonumber(amount) * UNITS[unit] or default
end

local function ulen(s)
  return utf8.len(s) or #s
end

-- Characters on one text line, and the inset of one cell, in characters.
local function line_capacity()
  local vars = PANDOC_WRITER_OPTIONS.variables
  local char = CHAR_EM * to_pt(vars.fontsize, 10)
  return to_pt(vars['md2pdf-textwidth'], 170 * UNITS.mm) / char, INSET_PT / char
end

-- Widest cell (max-content) and longest word (min-content) of each column,
-- in characters. `nil` when a cell spans: the columns are then left to typst.
local function measure(tbl, n)
  local widest, longest = {}, {}
  for i = 1, n do
    widest[i], longest[i] = 0, 0
  end
  local rows = {}
  for _, row in ipairs(tbl.head.rows) do
    table.insert(rows, row)
  end
  for _, body in ipairs(tbl.bodies) do
    for _, part in ipairs({ body.head, body.body }) do
      for _, row in ipairs(part) do
        table.insert(rows, row)
      end
    end
  end
  for _, row in ipairs(tbl.foot.rows) do
    table.insert(rows, row)
  end
  for _, row in ipairs(rows) do
    for col, cell in ipairs(row.cells) do
      if cell.col_span > 1 or cell.row_span > 1 or col > n then
        return nil
      end
      local text = pandoc.utils.stringify(cell.contents)
      widest[col] = math.max(widest[col], ulen(text))
      for word in text:gmatch('%S+') do
        longest[col] = math.max(longest[col], ulen(word) + 1)
      end
    end
  end
  return widest, longest
end

-- HTML auto layout: each column gets its longest word, the room left goes to
-- the columns in proportion to their remaining text. `nil`: all fits as is.
local function fractions(widest, longest, n)
  local line, pad = line_capacity()
  local room = line - n * pad
  local sum_widest, sum_longest = 0, 0
  for i = 1, n do
    sum_widest = sum_widest + widest[i]
    sum_longest = sum_longest + longest[i]
  end
  if sum_widest <= room then
    return nil
  end
  local share = math.max(0, room - sum_longest) / (sum_widest - sum_longest)
  local widths, total = {}, 0
  for i = 1, n do
    widths[i] = longest[i] + (widest[i] - longest[i]) * share + pad
    total = total + widths[i]
  end
  for i = 1, n do
    widths[i] = widths[i] / total
  end
  return widths
end

function Table(tbl)
  local n = #tbl.colspecs
  local first = tbl.colspecs[1][2]
  if first == nil then
    return nil
  end
  for _, spec in ipairs(tbl.colspecs) do
    if spec[2] == nil or math.abs(spec[2] - first) > 0.001 then
      return nil
    end
  end

  local widest, longest = measure(tbl, n)
  local widths = widest and fractions(widest, longest, n)
  for i, spec in ipairs(tbl.colspecs) do
    spec[2] = widths and widths[i] or nil
  end
  return tbl
end
