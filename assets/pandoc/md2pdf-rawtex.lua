-- md2pdf, typst engine only: the raw TeX / ConTeXt commands common in notes
-- become typst code. The typst writer drops raw TeX silently; anything not
-- handled here is reported as a warning instead.

-- ConTeXt list names to heading levels: pandoc maps `#` to `section`.
local levels = { section = 1, subsection = 2, subsubsection = 3, subsubsubsection = 4 }

-- Table of contents depth, narrowed by a preceding `\setupcombinedlist`.
local depth = 3

local skips = { smallskip = '0.25em', medskip = '0.5em', bigskip = '1em' }
local units = { pt = true, mm = true, cm = true, ['in'] = true, em = true }

local reported = {}

local function report(name)
  if not reported[name] then
    reported[name] = true
    pandoc.log.warn('typst ignores raw TeX \\' .. name)
  end
end

-- TeX argument text to typst markup, through pandoc's own LaTeX reader.
local function markup(tex)
  return pandoc.write(pandoc.read(tex, 'latex'), 'typst'):gsub('%s+$', '')
end

local function block_command(line)
  local list = line:match('^\\setupcombinedlist%[content%]%[.-list=(%b{})')
  if list then
    local deepest = 0
    for name in list:sub(2, -2):gmatch('[^,%s]+') do
      deepest = math.max(deepest, levels[name] or 0)
    end
    depth = deepest > 0 and deepest or depth
    return ''
  end
  if line:match('^\\pagebreak') or line:match('^\\newpage') or line:match('^\\clearpage')
    or line:match('^\\page%f[^%a]') then
    return '#pagebreak(weak: true)'
  end
  if line:match('^\\placecontent') then
    return ('#outline(title: none, depth: %d)'):format(depth)
  end
  if line:match('^\\completecontent') or line:match('^\\tableofcontents') then
    return ('#outline(depth: %d)'):format(depth)
  end
  local text = line:match('^\\centerline(%b{})')
  if text then
    return '#align(center)[' .. markup(text:sub(2, -2)) .. ']'
  end

  -- TeX and typst share these units; `\baselineskip` and friends do not map.
  local amount, unit = line:match('^\\vspace%*?{%s*([%d.]+)%s*(%a%a)%s*}')
  if amount and units[unit] then
    return '#v(' .. amount .. unit .. ')'
  end
  local skip = skips[line:match('^\\(%a+)%s*$') or '']
  if skip then
    return '#v(' .. skip .. ')'
  end

  report(line:match('^\\(%a+)') or line)
  return ''
end

local function is_tex(el)
  return el.format == 'tex' or el.format == 'latex' or el.format == 'context'
end

function RawBlock(el)
  if not is_tex(el) then
    return nil
  end
  local out = {}
  for line in el.text:gmatch('[^\n]+') do
    local code = block_command(line:match('^%s*(.-)%s*$'))
    if code ~= '' then
      table.insert(out, code)
    end
  end
  return #out > 0 and pandoc.RawBlock('typst', table.concat(out, '\n')) or {}
end

function RawInline(el)
  if not is_tex(el) then
    return nil
  end
  if el.text:match('^\\hfill') then
    return pandoc.RawInline('typst', '#h(1fr)')
  end
  if el.text:match('^\\newline') or el.text == '\\\\' then
    return pandoc.RawInline('typst', '#linebreak()')
  end
  report(el.text:match('^\\(%a+)') or el.text)
  return {}
end
