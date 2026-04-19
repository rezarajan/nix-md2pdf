{
  description = "Convert Markdown to PDF with Python, Mermaid direct PDF output, Pandoc, and a title page";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        python = pkgs.python3.withPackages (ps: [
          ps.pyyaml
        ]);

        headerTex = pkgs.writeText "md2pdf-header.tex" ''
          \usepackage[a4paper,margin=0.85in,top=0.9in,bottom=0.9in]{geometry}

          \usepackage{fontspec}
          \setmainfont{TeX Gyre Termes}
          \setsansfont{TeX Gyre Heros}
          \setmonofont{DejaVu Sans Mono}

          \usepackage{longtable}
          \usepackage{booktabs}
          \usepackage{array}
          \usepackage{caption}
          \usepackage{graphicx}
          \usepackage{etoolbox}
          \usepackage{microtype}
          \usepackage{xurl}
          \usepackage[normalem]{ulem}
          \usepackage{hyperref}
          \usepackage{pdflscape}

          \setlength{\LTleft}{0pt}
          \setlength{\LTright}{0pt}
          \renewcommand{\arraystretch}{1.06}
          \setlength{\tabcolsep}{3.5pt}
          \setlength{\parindent}{0pt}
          \setlength{\parskip}{0.45em}
          \emergencystretch=2em

          \urlstyle{same}
          \hypersetup{
            colorlinks=false,
            hidelinks=false,
            pdfborder={0 0 0}
          }

          \let\mdtwopdforighref\href
          \renewcommand{\href}[2]{\mdtwopdforighref{#1}{\uline{#2}}}

          \let\mdtwopdforigurl\url
          \renewcommand{\url}[1]{\href{#1}{\nolinkurl{#1}}}

          \AtBeginEnvironment{longtable}{\small}
        '';

        mermaidConfig = pkgs.writeText "mermaid-config.json" ''
          {
            "htmlLabels": false
          }
        '';

        filtersLua = pkgs.writeText "filters.lua" ''
          local stringify = pandoc.utils.stringify

          local function clamp(x, lo, hi)
            if x < lo then return lo end
            if x > hi then return hi end
            return x
          end

          local function cell_text_len(cell)
            local s = stringify(cell)
            s = s:gsub("%s+", " ")
            return #s
          end

          local function is_probable_url(text)
            return text:match("^%a+://") ~= nil
              or text:match("^www%.") ~= nil
              or text:match("^doi:") ~= nil
          end

          local function insert_breaks_in_long_token(text)
            if is_probable_url(text) then
              return text
            end

            if #text < 12 then
              return text
            end

            text = text
              :gsub("/", "/\226\128\139")
              :gsub("%-", "-\226\128\139")
              :gsub("_", "_\226\128\139")
              :gsub("([%,%;%:%)])", "%1\226\128\139")

            local out = {}
            local run = ""

            local function flush_run()
              if run == "" then
                return
              end

              if #run >= 12 then
                local i = 1
                while i <= #run do
                  local j = math.min(i + 7, #run)
                  table.insert(out, run:sub(i, j))
                  if j < #run then
                    table.insert(out, "\226\128\139")
                  end
                  i = j + 1
                end
              else
                table.insert(out, run)
              end

              run = ""
            end

            for i = 1, #text do
              local ch = text:sub(i, i)
              if ch:match("[%w]") then
                run = run .. ch
              else
                flush_run()
                table.insert(out, ch)
              end
            end
            flush_run()

            return table.concat(out)
          end

          local function soften_inlines(inlines)
            local out = {}
            for _, inline in ipairs(inlines) do
              if inline.t == "Str" then
                table.insert(out, pandoc.Str(insert_breaks_in_long_token(inline.text)))
              else
                table.insert(out, inline)
              end
            end
            return out
          end

          local function soften_cell(cell)
            local new_blocks = {}

            for _, blk in ipairs(cell.contents) do
              if blk.t == "Plain" or blk.t == "Para" then
                blk.content = soften_inlines(blk.content)
                table.insert(new_blocks, blk)
              else
                table.insert(new_blocks, blk)
              end
            end

            cell.contents = new_blocks
            return cell
          end

          local function collect_rows(tbl)
            local rows = {}

            if tbl.head and tbl.head.rows then
              for _, row in ipairs(tbl.head.rows) do
                table.insert(rows, row)
              end
            end

            if tbl.bodies then
              for _, body in ipairs(tbl.bodies) do
                if body.head then
                  for _, row in ipairs(body.head) do
                    table.insert(rows, row)
                  end
                end
                if body.body then
                  for _, row in ipairs(body.body) do
                    table.insert(rows, row)
                  end
                end
              end
            end

            if tbl.foot and tbl.foot.rows then
              for _, row in ipairs(tbl.foot.rows) do
                table.insert(rows, row)
              end
            end

            return rows
          end

          local function analyze_table(tbl)
            local n = #tbl.colspecs
            local rows = collect_rows(tbl)
            local weights = {}
            local total = 0
            local longest_cell = 0

            for i = 1, n do
              weights[i] = 8
            end

            for _, row in ipairs(rows) do
              for i, cell in ipairs(row.cells) do
                local len = cell_text_len(cell)
                if len > longest_cell then
                  longest_cell = len
                end
                weights[i] = math.max(weights[i], clamp(math.sqrt(len) * 2.6, 8, 42))
              end
            end

            for i = 1, n do
              weights[i] = clamp(weights[i], 8, 30)
              total = total + weights[i]
            end

            return {
              colcount = n,
              weights = weights,
              total = total,
              longest_cell = longest_cell,
            }
          end

          local function should_landscape(stats)
            -- Practical heuristic:
            -- many columns, or enough total estimated width to justify rotation.
            if stats.colcount >= 7 then
              return true
            end
            if stats.total >= 95 then
              return true
            end
            if stats.colcount >= 5 and stats.longest_cell >= 80 then
              return true
            end
            return false
          end

          function Table(tbl)
            local n = #tbl.colspecs
            if n == 0 then
              return tbl
            end

            local rows = collect_rows(tbl)

            for _, row in ipairs(rows) do
              for i, cell in ipairs(row.cells) do
                row.cells[i] = soften_cell(cell)
              end
            end

            local stats = analyze_table(tbl)
            local total = 0
            for i = 1, n do
              total = total + stats.weights[i]
            end

            for i = 1, n do
              local align = tbl.colspecs[i][1]
              local width = stats.weights[i] / total
              tbl.colspecs[i] = { align, width }
            end

            if should_landscape(stats) then
              return {
                pandoc.RawBlock("latex", "\\begin{landscape}"),
                tbl,
                pandoc.RawBlock("latex", "\\end{landscape}")
              }
            end

            return tbl
          end
        '';

        md2pdfPy = pkgs.writeText "md2pdf.py" ''
          #!/usr/bin/env python3
          import argparse
          import pathlib
          import re
          import subprocess
          import sys
          import tempfile

          import yaml

          FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n", re.DOTALL)
          MERMAID_BLOCK_RE = re.compile(
              r"```[ \t]*mermaid[ \t]*\n(.*?)\n```",
              re.DOTALL
          )
          FENCED_BLOCK_RE = re.compile(
              r"(^```[^\n]*\n.*?^```[ \t]*$)",
              re.DOTALL | re.MULTILINE
          )

          def run(cmd, **kwargs):
              subprocess.run(cmd, check=True, **kwargs)

          def tex_escape(value: str) -> str:
              replacements = {
                  "\\": r"\textbackslash{}",
                  "&": r"\&",
                  "%": r"\%",
                  "$": r"\$",
                  "#": r"\#",
                  "_": r"\_",
                  "{": r"\{",
                  "}": r"\}",
                  "~": r"\textasciitilde{}",
                  "^": r"\textasciicircum{}",
              }
              return "".join(replacements.get(ch, ch) for ch in value)

          def parse_frontmatter(text: str):
              match = FRONTMATTER_RE.match(text)
              if not match:
                  return {}, text

              raw = match.group(1)
              body = text[match.end():]
              data = yaml.safe_load(raw) or {}
              if not isinstance(data, dict):
                  data = {}
              return data, body

          def make_title_page_tex(meta: dict) -> str:
              title = meta.get("title")
              subtitle = meta.get("subtitle")
              author = meta.get("author")
              date = meta.get("date")

              if not title:
                  return ""

              if isinstance(author, str):
                  authors = [author]
              elif isinstance(author, list):
                  authors = [str(a) for a in author]
              else:
                  authors = []

              parts = []
              parts.append(r"\begin{titlepage}")
              parts.append(r"\centering")
              parts.append(r"\vspace*{\fill}")
              parts.append(r"{\Huge\bfseries " + tex_escape(str(title)) + r"\par}")

              if subtitle:
                  parts.append(r"\vspace{1em}")
                  parts.append(r"{\Large " + tex_escape(str(subtitle)) + r"\par}")

              if authors:
                  parts.append(r"\vspace{2em}")
                  parts.append(r"{\large")
                  for idx, a in enumerate(authors):
                      if idx > 0:
                        parts.append(r"\\")
                      parts.append(tex_escape(a))
                  parts.append(r"\par}")

              if date:
                  parts.append(r"\vspace{1.5em}")
                  parts.append(r"{\large " + tex_escape(str(date)) + r"\par}")

              parts.append(r"\vspace*{\fill}")
              parts.append(r"\end{titlepage}")
              parts.append("")
              return "\n".join(parts)

          def escape_currency_dollars(text: str) -> str:
              parts = FENCED_BLOCK_RE.split(text)
              out = []

              for part in parts:
                  if not part:
                      continue

                  if FENCED_BLOCK_RE.match(part):
                      out.append(part)
                      continue

                  part = re.sub(r'(?<!\\)\$(?=\d)', r'\\$', part)
                  out.append(part)

              return "".join(out)

          def render_mermaid_blocks(text: str, tmpdir: pathlib.Path) -> str:
              counter = 0

              def repl(match):
                  nonlocal counter
                  counter += 1

                  mermaid_src = match.group(1).strip() + "\n"
                  mmd_path = tmpdir / f"diagram-{counter}.mmd"
                  pdf_path = tmpdir / f"diagram-{counter}.pdf"

                  mmd_path.write_text(mermaid_src, encoding="utf-8")

                  run([
                      "mmdc",
                      "-i", str(mmd_path),
                      "-o", str(pdf_path),
                      "-c", "${mermaidConfig}",
                      "--pdfFit",
                      "-b", "transparent",
                  ])

                  abs_pdf = tex_escape(str(pdf_path.resolve()))

                  return (
                      "\n"
                      "```{=latex}\n"
                      "\\begin{center}\n"
                      "\\includegraphics[width=\\linewidth,height=0.82\\textheight,keepaspectratio]{"
                      + abs_pdf
                      + "}\n"
                      "\\end{center}\n"
                      "```\n"
                  )

              return MERMAID_BLOCK_RE.sub(repl, text)

          def main():
              parser = argparse.ArgumentParser(
                  description="Convert Markdown to PDF with Mermaid diagrams and a title page."
              )
              parser.add_argument("input", help="Input markdown file")
              parser.add_argument("-o", "--output", help="Output PDF path")
              args = parser.parse_args()

              input_path = pathlib.Path(args.input).resolve()
              if not input_path.exists():
                  print(f"Input file not found: {input_path}", file=sys.stderr)
                  sys.exit(1)

              output_path = (
                  pathlib.Path(args.output).resolve()
                  if args.output
                  else input_path.with_suffix(".pdf")
              )

              with tempfile.TemporaryDirectory() as td:
                  tmpdir = pathlib.Path(td)
                  processed_md = tmpdir / "document.md"
                  titlepage_tex = tmpdir / "titlepage.tex"

                  source = input_path.read_text(encoding="utf-8")
                  meta, body = parse_frontmatter(source)

                  titlepage_tex.write_text(make_title_page_tex(meta), encoding="utf-8")

                  body = escape_currency_dollars(body)
                  processed_body = render_mermaid_blocks(body, tmpdir)
                  processed_md.write_text(processed_body, encoding="utf-8")

                  resource_path = f"{input_path.parent}:{tmpdir}"

                  common_cmd = [
                      "pandoc",
                      str(processed_md),
                      "--from=markdown+raw_tex+raw_attribute+pipe_tables+grid_tables+multiline_tables+table_captions",
                      "--standalone",
                      "--toc",
                      "--pdf-engine=xelatex",
                      f"--include-in-header=${headerTex}",
                      f"--include-before-body={titlepage_tex}",
                      f"--lua-filter=${filtersLua}",
                      f"--resource-path={resource_path}",
                      "-o", str(output_path),
                  ]

                  run(common_cmd)

              print(f"Wrote {output_path}")

          if __name__ == "__main__":
              main()
        '';
      in
      {
        packages.default = pkgs.writeShellApplication {
          name = "md2pdf";
          runtimeInputs = [
            python
            pkgs.pandoc
            pkgs.mermaid-cli
            pkgs.texliveFull
          ];
          text = ''
            exec ${python}/bin/python ${md2pdfPy} "$@"
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/md2pdf";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            python
            pkgs.pandoc
            pkgs.mermaid-cli
            pkgs.texliveFull
            self.packages.${system}.default
          ];
        };
      });
}
