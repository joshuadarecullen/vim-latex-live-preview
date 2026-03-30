" Copyright (C) 2012 Hong Xu

" This file is part of vim-live-preview.

" vim-live-preview is free software: you can redistribute it and/or modify it
" under the terms of the GNU General Public License as published by the Free
" Software Foundation, either version 3 of the License, or (at your option)
" any later version.

" vim-live-preview is distributed in the hope that it will be useful, but
" WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
" or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
" more details.

" You should have received a copy of the GNU General Public License along with
" vim-live-preview.  If not, see <http://www.gnu.org/licenses/>.


if v:version < 700
    finish
endif

" Check whether this script is already loaded
if exists("g:loaded_vim_live_preview")
    finish
endif
let g:loaded_vim_live_preview = 1

" Check mkdir feature
if (!exists("*mkdir"))
    echohl ErrorMsg
    echo 'vim-latex-live-preview: mkdir functionality required'
    echohl None
    finish
endif

" Setup python
if (has('python3'))
    let s:py_exe = 'python3'
elseif (has('python'))
    let s:py_exe = 'python'
else
    echohl ErrorMsg
    echo 'vim-latex-live-preview: python required'
    echohl None
    finish
endif

let s:saved_cpo = &cpo
set cpo&vim

let s:previewer = ''

" Run a shell command in background
function! s:RunInBackground(cmd)

execute s:py_exe "<< EEOOFF"

try:
    subprocess.Popen(
            vim.eval('a:cmd'),
            shell = True,
            universal_newlines = True,
            stdout=open(os.devnull, 'w'), stderr=subprocess.STDOUT)

except:
    pass
EEOOFF
endfunction

function! s:Compile()

    if !exists('b:livepreview_buf_data') ||
                \ has_key(b:livepreview_buf_data, 'preview_running') == 0
        return
    endif

    " Change directory to handle properly sourced files with \input and bib
    execute 'lcd ' . b:livepreview_buf_data['root_dir']

    " Write the current buffer in a temporary file
    silent exec 'write! ' . b:livepreview_buf_data['tmp_src_file']

    " Smart recompile: only run bib when .bib files changed
    if s:BibFilesChanged() && has_key(b:livepreview_buf_data, 'run_bib_cmd')
        call s:RunInBackground(b:livepreview_buf_data['run_cmd'] .
            \ ' && ' . b:livepreview_buf_data['run_bib_cmd'] .
            \ ' && ' . b:livepreview_buf_data['run_cmd'])
    else
        call s:RunInBackground(b:livepreview_buf_data['run_cmd'])
    endif

    lcd -
endfunction

function! s:StartPreview(...)
    " Prevent duplicate previews
    if exists('b:livepreview_buf_data') && get(b:livepreview_buf_data, 'preview_running', 0)
        echo 'Preview already running. Use :LLPStop to stop it first.'
        return
    endif
    let b:livepreview_buf_data = {}

    let b:livepreview_buf_data['py_exe'] = s:py_exe

    " This Pattern Matching will FAIL for multiline biblatex declarations,
    " in which case the `g:livepreview_use_biber` setting must be respected.
    let l:general_pattern = '^\\usepackage\[.*\]{biblatex}'
    let l:specific_pattern = 'backend=bibtex'
    let l:position = search(l:general_pattern, 'cw')
    if ( l:position != 0 )
        let l:matches = matchstr(getline(l:position), specific_pattern)
        if ( l:matches == '' )
            " expect s:use_biber=1
            if ( s:use_biber == 0 )
                let s:use_biber = 1
                echohl ErrorMsg
                echom "g:livepreview_use_biber not set or does not match `biblatex` usage in your document. Overridden!"
                echohl None
            endif
        else
            " expect s:use_biber=0
            if ( s:use_biber == 1 )
                let s:use_biber = 0
                echohl ErrorMsg
                echom "g:livepreview_use_biber is set but `biblatex` is explicitly using `bibtex`. Overridden!"
                echohl None
            endif
        endif
    else
        " expect s:use_biber=0
        " `biblatex` is not being used, this usually means we
        " are using `bibtex`
        " However, it is not a universal rule, so we do nothing.
    endif

    " Create a temp directory for current buffer
    execute s:py_exe "<< EEOOFF"
vim.command("let b:livepreview_buf_data['tmp_dir'] = '" +
        tempfile.mkdtemp(prefix="vim-latex-live-preview-") + "'")
EEOOFF

    let b:livepreview_buf_data['tmp_src_file'] =
                \ b:livepreview_buf_data['tmp_dir'] .
                \ expand('%:p:r')

    " Guess the root file which will be compiled, using first the argument
    " passed, then the first line declaration of the source file and
    " eventually fallback to the current file.
    " TODO: emulate -parse-first-line properly
    let l:root_line = substitute(getline(1),
                \ '\v^\s*\%\s*!TEX\s*root\s*\=\s*(.*)\s*$',
                \ '\1', '')

    if (a:0 > 0)
        let l:root_file = fnamemodify(a:1, ':p')
    elseif (l:root_line != getline(1) && strlen(l:root_line) > 0)                       " TODO: existence of `% !TEX` declaration condition must be cleaned...
        let l:root_file = fnamemodify(l:root_line, ':p')
    else
        let l:root_file = b:livepreview_buf_data['tmp_src_file']
    endif

    " Hack for complex project trees: recreate the tree in tmp_dir
    " Build tree for tmp_src_file (copy of the current buffer)
    let l:tmp_src_dir = fnamemodify(b:livepreview_buf_data['tmp_src_file'], ':p:h')
    if (!isdirectory(l:tmp_src_dir))
        silent call mkdir(l:tmp_src_dir, 'p')
    endif
    " Build tree for root_file (main tex file, which might be tmp_src_file,
    " ie. the current file)
    if (l:root_file == b:livepreview_buf_data['tmp_src_file'])                          " if root file is the current file
        let l:tmp_root_dir = l:tmp_src_dir
    else
        let l:tmp_root_dir = b:livepreview_buf_data['tmp_dir'] . fnamemodify(l:root_file, ':p:h')
        if (!isdirectory(l:tmp_root_dir))
            silent call mkdir(l:tmp_root_dir, 'p')
        endif
    endif

    " Escape pathnames
    let l:root_file = fnameescape(l:root_file)
    let l:tmp_root_dir_raw = l:tmp_root_dir
    let l:tmp_root_dir = fnameescape(l:tmp_root_dir)
    let b:livepreview_buf_data['tmp_dir'] = fnameescape(b:livepreview_buf_data['tmp_dir'])
    let b:livepreview_buf_data['tmp_src_file'] = fnameescape(b:livepreview_buf_data['tmp_src_file'])

    " Change directory to handle properly sourced files with \input and bib
    " TODO: get rid of lcd
    if (l:root_file == b:livepreview_buf_data['tmp_src_file'])                          " if root file is the current file
        let b:livepreview_buf_data['root_dir'] = fnameescape(expand('%:p:h'))
    else
        let b:livepreview_buf_data['root_dir'] = fnamemodify(l:root_file, ':p:h')
    endif
    execute 'lcd ' . b:livepreview_buf_data['root_dir']

    " Write the current buffer in a temporary file
    silent exec 'write! ' . b:livepreview_buf_data['tmp_src_file']

    let l:tmp_out_file = l:tmp_root_dir . '/' .
                \ fnamemodify(l:root_file, ':t:r') . '.pdf'

    let b:livepreview_buf_data['run_cmd'] =
                \ 'env ' .
                \       'TEXMFOUTPUT=' . l:tmp_root_dir . ' ' .
                \       'TEXINPUTS=' . s:static_texinputs
                \                    . ':' . l:tmp_root_dir
                \                    . ':' . b:livepreview_buf_data['root_dir']
                \                    . ': ' .
                \ s:engine . ' ' .
                \       '-shell-escape ' .
                \       '-interaction=nonstopmode ' .
                \       '-output-directory=' . l:tmp_root_dir . ' ' .
                \       l:root_file
                " lcd can be avoided thanks to root_dir in TEXINPUTS

    silent call system(b:livepreview_buf_data['run_cmd'])
    if v:shell_error != 0
        echo 'Failed to compile'
        lcd -
        return
    endif

    " Enable compilation of bibliography:
    let l:bib_files = split(globpath(b:livepreview_buf_data['root_dir'], '**/*.bib', 1), "\n")  " TODO: fails if unused bibfiles
    if len(l:bib_files) > 0
        for bib_file in l:bib_files
            let bib_fn = fnamemodify(bib_file, ':t')
            call writefile(readfile(bib_file),
                        \ l:tmp_root_dir_raw . '/' . bib_fn)                            " TODO: may fail if same bibfile names in different dirs
        endfor

        if s:use_biber
            let s:bibexec = 'biber --input-directory=' . l:tmp_root_dir . '--output-directory=' . l:tmp_root_dir . ' ' . l:root_file
        else
            " The alternative to this pushing and popping is to write
            " temporary files to a `.tmp` folder in the current directory and
            " then `mv` them to `/tmp` and delete the `.tmp` directory.
            let s:bibexec = 'pushd ' . l:tmp_root_dir . ' && bibtex *.aux' . ' && popd'
        endif

        let b:livepreview_buf_data['run_bib_cmd'] =
                \       'env ' .
                \               'TEXMFOUTPUT=' . l:tmp_root_dir . ' ' .
                \               'TEXINPUTS=' . s:static_texinputs
                \                            . ':' . l:tmp_root_dir
                \                            . ':' . b:livepreview_buf_data['root_dir']
                \                            . ': ' .
                \ ' && ' . s:bibexec

        silent call system(b:livepreview_buf_data['run_bib_cmd'])
        silent call system(b:livepreview_buf_data['run_cmd'])
    endif
    if v:shell_error != 0
        echo 'Failed to compile bibliography'
        lcd -
        return
    endif

    call s:RunInBackground(s:previewer . ' ' . l:tmp_out_file)

    lcd -

    let b:livepreview_buf_data['preview_running'] = 1
endfunction

" Initialization code
function! s:Initialize()
    let l:ret = 0
    execute s:py_exe "<< EEOOFF"
try:
    import vim
    import tempfile
    import subprocess
    import os
except:
    vim.command('let l:ret = 1')
EEOOFF

    if l:ret != 0
        return 'Python initialization failed.'
    endif

    function! s:ValidateExecutables( context, executables )
        let l:user_set = get(g:, a:context, '')
        if l:user_set != ''
            return l:user_set
        endif
        for possible_engine in a:executables
            if executable(possible_engine)
                return possible_engine
            endif
        endfor
        echohl ErrorMsg
        echo printf("vim-latex-live-preview: The defaults for %s are not executable.", a:context)
        echohl None
        throw "End execution"
    endfunction

    " Get the tex engine
    let s:engine = s:ValidateExecutables('livepreview_engine', ['pdflatex', 'xelatex'])

    " Get the previewer
    let s:previewer = s:ValidateExecutables('livepreview_previewer', ['evince', 'okular'])

     " Initialize texinputs directory list to environment variable TEXINPUTS if g:livepreview_texinputs is not set
    let s:static_texinputs = get(g:, 'livepreview_texinputs', $TEXINPUTS)

    " Select bibliography executable
    let s:use_biber = get(g:, 'livepreview_use_biber', 0)

    return 0
endfunction

try
    let s:init_msg = s:Initialize()
catch
    finish
endtry

if type(s:init_msg) == type('')
    echohl ErrorMsg
    echo 'vim-live-preview: ' . s:init_msg
    echohl None
endif

unlet! s:init_msg

command! -nargs=* LLPStartPreview call s:StartPreview(<f-args>)

function! LLPStop()
    if exists('b:livepreview_buf_data')
        " Clean up temp directory
        if has_key(b:livepreview_buf_data, 'tmp_dir')
            let l:tmp = substitute(b:livepreview_buf_data['tmp_dir'], "^'\\|'$", '', 'g')
            if isdirectory(l:tmp)
                call delete(l:tmp, 'rf')
            endif
        endif
        unlet b:livepreview_buf_data
        echo 'Preview stopped'
    else
        echo 'No preview running'
    endif
endfunction

command! LLPStop call LLPStop()

if get(g:, 'livepreview_cursorhold_recompile', 1)
    autocmd CursorHold,CursorHoldI,BufWritePost * call s:Compile()
else
    autocmd BufWritePost * call s:Compile()
endif

" Forward search: Jump PDF to current cursor position in tex file
" Requires: okular, compilation with -synctex=1
function! LLPSyncForward()
    let l:line = line('.')
    let l:col = col('.')
    let l:tex_file = expand('%:p')

    " Get PDF path from livepreview if running
    if exists('b:livepreview_buf_data') && has_key(b:livepreview_buf_data, 'tmp_dir')
        let l:tmp_dir = substitute(b:livepreview_buf_data['tmp_dir'], "^'\\|'$", '', 'g')
        let l:root_dir = b:livepreview_buf_data['root_dir']
        let l:pdf_file = l:tmp_dir . l:root_dir . '/' . expand('%:t:r') . '.pdf'
        let l:tex_file = l:tmp_dir . expand('%:p:r')
    else
        let l:pdf_file = expand('%:p:r') . '.pdf'
    endif

    if !filereadable(l:pdf_file)
        echohl WarningMsg
        echo 'PDF not found: ' . l:pdf_file
        echohl None
        return
    endif

    " Okular forward search command (avoid double --unique if already in previewer)
    let l:unique = s:previewer =~# '--unique' ? '' : '--unique '
    let l:cmd = s:previewer . ' ' . l:unique . '"' . l:pdf_file . '#src:' . l:line . ' ' . l:tex_file . '"'
    call s:RunInBackground(l:cmd)
endfunction

function! s:SyncForwardDelayed(timer)
    call LLPSyncForward()
endfunction

" Compile LaTeX and show errors in quickfix
function! LLPCompileErrors()
    let l:tex_file = expand('%:p')
    let l:tex_dir = expand('%:p:h')
    write

    let l:cmd = 'cd ' . shellescape(l:tex_dir) . ' && ' . s:engine . ' -file-line-error -interaction=nonstopmode ' . shellescape(l:tex_file) . ' 2>&1'
    let l:output = system(l:cmd)

    let l:errors = []
    for l:line in split(l:output, '\n')
        let l:match = matchlist(l:line, '^\([^:]*\.tex\):\(\d\+\):\s*\(.*\)$')
        if !empty(l:match)
            call add(l:errors, {
                \ 'filename': l:tex_dir . '/' . l:match[1],
                \ 'lnum': str2nr(l:match[2]),
                \ 'text': l:match[3],
                \ 'type': 'E'
                \ })
        endif
    endfor

    call setqflist(l:errors)
    if empty(l:errors)
        echo 'No errors found!'
        cclose
    else
        copen
    endif
endfunction

command! LLPSyncForward call LLPSyncForward()
command! LLPCompileErrors call LLPCompileErrors()

" Auto-sync after save (optional, controlled by g:livepreview_autosync)
if get(g:, 'livepreview_autosync', 0)
    autocmd BufWritePost *.tex call timer_start(get(g:, 'livepreview_autosync_delay', 1500), function('s:SyncForwardDelayed'))
endif

" Cursor tracking - PDF follows cursor position
let s:cursor_track_enabled = 0
let s:cursor_track_timer = -1
let s:cursor_track_last_line = -1

function! s:CursorTrackSync(timer)
    let l:cur_line = line('.')
    " Only sync if line changed and preview is running
    if l:cur_line != s:cursor_track_last_line
                \ && exists('b:livepreview_buf_data')
                \ && get(b:livepreview_buf_data, 'preview_running', 0)
        let s:cursor_track_last_line = l:cur_line
        call LLPSyncForward()
    endif
endfunction

function! s:CursorTrackHandler()
    " Cancel pending timer
    if s:cursor_track_timer != -1
        call timer_stop(s:cursor_track_timer)
    endif
    " Start new debounced timer (default 200ms, configurable)
    let l:delay = get(g:, 'livepreview_cursor_track_delay', 200)
    let s:cursor_track_timer = timer_start(l:delay, function('s:CursorTrackSync'))
endfunction

function! LLPCursorTrackOn()
    let s:cursor_track_enabled = 1
    let s:cursor_track_last_line = -1
    augroup LLPCursorTrack
        autocmd!
        autocmd CursorMoved,CursorMovedI *.tex call s:CursorTrackHandler()
    augroup END
    echo 'PDF cursor tracking ON'
endfunction

function! LLPCursorTrackOff()
    let s:cursor_track_enabled = 0
    if s:cursor_track_timer != -1
        call timer_stop(s:cursor_track_timer)
        let s:cursor_track_timer = -1
    endif
    augroup LLPCursorTrack
        autocmd!
    augroup END
    echo 'PDF cursor tracking OFF'
endfunction

function! LLPCursorTrackToggle()
    if s:cursor_track_enabled
        call LLPCursorTrackOff()
    else
        call LLPCursorTrackOn()
    endif
endfunction

command! LLPCursorTrackOn call LLPCursorTrackOn()
command! LLPCursorTrackOff call LLPCursorTrackOff()
command! LLPCursorTrackToggle call LLPCursorTrackToggle()

" ============================================================================
" Feature: Clean Auxiliary Files
" ============================================================================
let s:aux_extensions = ['aux', 'log', 'toc', 'lof', 'lot', 'bbl', 'blg', 'idx',
    \ 'ilg', 'ind', 'out', 'synctex.gz', 'fls', 'fdb_latexmk', 'nav', 'snm',
    \ 'vrb', 'bcf', 'run.xml', 'xdv']

function! LLPClean(...)
    let l:extensions = get(g:, 'livepreview_aux_extensions', s:aux_extensions)
    let l:clean_dir = a:0 > 0 ? fnamemodify(a:1, ':p:h') :
        \ (exists('b:livepreview_buf_data') && has_key(b:livepreview_buf_data, 'root_dir')
        \ ? b:livepreview_buf_data['root_dir'] : expand('%:p:h'))
    let l:base = expand('%:t:r')
    let l:deleted = []
    for ext in l:extensions
        let l:file = l:clean_dir . '/' . l:base . '.' . ext
        if filereadable(l:file) && delete(l:file) == 0
            call add(l:deleted, l:base . '.' . ext)
        endif
    endfor
    echo empty(l:deleted) ? 'No auxiliary files found' : 'Cleaned: ' . join(l:deleted, ', ')
endfunction

function! LLPCleanAll()
    call LLPClean()
    if exists('b:livepreview_buf_data') && has_key(b:livepreview_buf_data, 'tmp_dir')
        let l:tmp = substitute(b:livepreview_buf_data['tmp_dir'], "^'\\|'$", '', 'g')
        if isdirectory(l:tmp)
            call delete(l:tmp, 'rf')
            echo ' + temp directory'
        endif
    endif
endfunction

command! -nargs=? -complete=dir LLPClean call LLPClean(<f-args>)
command! LLPCleanAll call LLPCleanAll()

" ============================================================================
" Feature: Word Count
" ============================================================================
function! LLPWordCount()
    let l:cmd = get(g:, 'livepreview_texcount_cmd', 'texcount')
    if !executable(l:cmd)
        echohl ErrorMsg | echo 'texcount not found (install texlive-extra-utils)' | echohl None
        return
    endif
    if &modified | silent write | endif
    let l:opts = get(g:, 'livepreview_texcount_opts', '-merge -q')
    let l:output = system(l:cmd . ' ' . l:opts . ' ' . shellescape(expand('%:p')))
    let l:words = matchstr(l:output, '\d\+')
    echo empty(l:words) ? l:output : 'Words: ' . l:words
    return l:words
endfunction

function! LLPWordCountVerbose()
    let l:cmd = get(g:, 'livepreview_texcount_cmd', 'texcount')
    if !executable(l:cmd)
        echohl ErrorMsg | echo 'texcount not found' | echohl None
        return
    endif
    if &modified | silent write | endif
    let l:output = system(l:cmd . ' -merge ' . shellescape(expand('%:p')))
    botright new
    setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
    silent put =l:output
    1delete _
    resize 15
    setlocal nomodifiable
endfunction

command! LLPWordCount call LLPWordCount()
command! LLPWordCountVerbose call LLPWordCountVerbose()

" ============================================================================
" Feature: Log Viewer
" ============================================================================
function! s:GetLogFile()
    if exists('b:livepreview_buf_data') && has_key(b:livepreview_buf_data, 'tmp_dir')
        let l:tmp = substitute(b:livepreview_buf_data['tmp_dir'], "^'\\|'$", '', 'g')
        let l:root = b:livepreview_buf_data['root_dir']
        return l:tmp . l:root . '/' . expand('%:t:r') . '.log'
    endif
    return expand('%:p:r') . '.log'
endfunction

function! LLPLog()
    let l:log = s:GetLogFile()
    if !filereadable(l:log)
        echohl WarningMsg | echo 'Log not found: ' . l:log | echohl None
        return
    endif
    let l:height = get(g:, 'livepreview_log_height', 15)
    let l:bufname = 'LLPLog:' . expand('%:t:r')
    let l:existing = bufwinnr(l:bufname)
    if l:existing != -1
        execute l:existing . 'wincmd w'
        setlocal modifiable
        %delete _
        execute 'read ' . fnameescape(l:log)
        1delete _
    else
        execute 'botright ' . l:height . 'split'
        execute 'edit ' . fnameescape(l:log)
        execute 'file ' . l:bufname
        setlocal buftype=nofile bufhidden=wipe noswapfile nowrap
    endif
    setlocal nomodifiable
    " Highlight errors and warnings
    syntax match LLPLogError /^!.*/
    syntax match LLPLogWarning /\vWarning:|LaTeX Warning/
    highlight link LLPLogError ErrorMsg
    highlight link LLPLogWarning WarningMsg
    call search('\v^!|Warning:', 'w')
endfunction

function! LLPLogToggle()
    let l:bufname = 'LLPLog:' . expand('%:t:r')
    let l:win = bufwinnr(l:bufname)
    if l:win != -1
        execute l:win . 'wincmd c'
    else
        call LLPLog()
    endif
endfunction

command! LLPLog call LLPLog()
command! LLPLogToggle call LLPLogToggle()

" ============================================================================
" Feature: Inverse Search Setup
" ============================================================================
function! LLPSetupInverseSearch()
    let l:server = get(g:, 'livepreview_servername', v:servername)
    if empty(l:server)
        let l:server = 'VIM'
    endif
    let l:cmd = 'vim --servername ' . l:server . ' --remote-silent +%l %f'
    echo 'Configure okular for inverse search:'
    echo '  Settings -> Configure Okular -> Editor'
    echo '  Set: Custom Text Editor'
    echo '  Command: ' . l:cmd
    echo ''
    echo 'Start vim with: vim --servername ' . l:server
    echo 'Current servername: ' . (empty(v:servername) ? '(none)' : v:servername)
endfunction

command! LLPSetupInverseSearch call LLPSetupInverseSearch()

" ============================================================================
" Feature: Smart Recompile (only run bib when .bib files change)
" ============================================================================
let s:bib_mtimes = {}

function! s:BibFilesChanged()
    if !get(g:, 'livepreview_smart_bib', 1)
        return 1
    endif
    if !exists('b:livepreview_buf_data') || !has_key(b:livepreview_buf_data, 'root_dir')
        return 0
    endif
    let l:root = b:livepreview_buf_data['root_dir']
    let l:bibs = split(globpath(l:root, '**/*.bib', 1), "\n")
    let l:changed = 0
    for l:bib in l:bibs
        let l:mtime = getftime(l:bib)
        if l:mtime != get(s:bib_mtimes, l:bib, 0)
            let s:bib_mtimes[l:bib] = l:mtime
            let l:changed = 1
        endif
    endfor
    return l:changed
endfunction

let &cpo = s:saved_cpo
unlet! s:saved_cpo

" vim703: cc=80
" vim:fdm=marker et ts=4 tw=78 sw=4
