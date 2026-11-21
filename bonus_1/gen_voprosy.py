# -*- coding: utf-8 -*-
# Генерирует voprosy.html (вопросы+ответы по коду бонусного задания №1),
# Затем PDF делается командой:  weasyprint voprosy.html voprosy.pdf
import html, pathlib, sys

sys.path.insert(0, pathlib.Path(__file__).parent.as_posix())
from gen_voprosy_data import QA

BASE = pathlib.Path(__file__).parent

FILES = ['src/bb_cov_runtime.c', 'tools/bb_cov_finalize.py', 'patch/genhtml.patch',
         'tools/lib_common.sh', 'tools/build_project.sh', 'run_project.sh',
         'verify/check_compat.sh']


def build(f):
    p = BASE.joinpath(f)
    lines = p.read_text(encoding='utf-8').splitlines()
    qa = QA.get(f, [])
    qa_by_line = {t[0] for t in qa}

    sec = ['<section class="file">']
    sec.append(f'<h2 class="fname">{html.escape(f)}</h2>')
    sec.append('<div class="listing"><table class="code"><tbody>')
    for i, ln in enumerate(lines, 1):
        cls = 'mline' if (i in qa_by_line) else ''
        sec.append(f'<tr><td class="n">{i}</td><td class="l {cls}">{html.escape(ln)}</td></tr>')
    sec.append('</tbody></table></div>')
    sec.append('<table class="qa"><thead><tr><th>№ строки</th><th>Вопрос</th><th>Ответ</th></tr></thead><tbody>')
    for lineno, q, a in sorted(qa, key=lambda t: t[0]):
        sec.append(f'<tr><td class="n">{lineno}</td><td class="q">{html.escape(q)}</td><td class="a">{html.escape(a)}</td></tr>')
    sec.append('</tbody></table></section>')
    return ''.join(sec)


CSS = '''
@page { size: A4; margin: 1.4cm; }
body { font-family: "DejaVu Sans", "Liberation Sans", sans-serif; font-size: 9.5pt; color:#111; }
h1 { font-size: 17pt; border-bottom: 2px solid #333; padding-bottom:4px; }
h2.fname { font-size: 12pt; background:#222; color:#fff; padding:4px 8px; border-radius:3px; margin-top:18px; }
table.code { border-collapse: collapse; width:100%; font-family:"DejaVu Sans Mono", monospace; font-size:7.4pt;}
table.code td { padding:0 6px; vertical-align:top; }
table.code td.n { color:#888; width:28px; user-select:none; }
table.code td.l { white-space:pre-wrap; }
table.code td.mline { background:#eef7ee; }
table.qa { border-collapse: collapse; width:100%; margin-top:8px; font-size:8.6pt; }
table.qa th { background:#444; color:#fff; padding:4px 6px; text-align:left; }
table.qa td { border:1px solid #ccc; padding:4px 6px; vertical-align:top; }
table.qa td.n { width:30px; text-align:center; color:#888; }
table.qa td.q { width:44%; }
section.file { page-break-before: always; }
'''


def main():
    parts = ['<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">'
             '<title>Вопросы по коду — бонус №1 (модификация genhtml)</title>'
             f'<style>{CSS}</style></head><body>']
    parts.append('<h1>Бонусное задание №1 — вопросы по коду (модификация genhtml)</h1>')
    parts.append('<p>Для каждого файла: листинг (подсвечены строки, по которым есть вопросы), '
                 'затем таблица «номер строки — вопрос — ответ».</p>')
    for f in FILES:
        parts.append(build(f))
    parts.append('</body></html>')

    out = BASE.joinpath('voprosy.html')
    out.write_text(''.join(parts), encoding='utf-8')
    print('html written:', out)
    print('sections:', len(FILES))


if __name__ == '__main__':
    main()