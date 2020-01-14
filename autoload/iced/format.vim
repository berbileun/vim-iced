let s:save_cpo = &cpo
set cpo&vim

let g:iced#format#does_overwrite_rules = get(g:, 'iced#format#does_overwrite_rules', v:false)
let g:iced#format#rule = get(g:, 'iced#format#rule', {})

function! s:set_indentation_rule() abort
  call iced#cache#do_once('set-indentation-rule', {->
        \ iced#util#has_status(
        \   iced#nrepl#op#iced#sync#set_indentation_rules(
        \     g:iced#format#rule,
        \     g:iced#format#does_overwrite_rules),
        \   'done')})
endfunction

function! s:__format_finally(args) abort
  let current_bufnr = get(a:args, 'back_to_bufnr', bufnr('%'))
  let different_buffer = (current_bufnr != a:args.bufnr)
  if different_buffer | call iced#buffer#focus(a:args.bufnr) | endif

  setl modifiable
  let @@ = a:args.reg_save
  call winrestview(a:args.view)
  call iced#system#get('sign').refresh({'signs': a:args.signs})

  if different_buffer | call iced#buffer#focus(current_bufnr) | endif
endfunction

"" iced#format#all {{{
function! s:__format_all(resp, finally_args) abort
  let current_bufnr = bufnr('%')
  if current_bufnr != a:finally_args.bufnr
    call iced#buffer#focus(a:finally_args.bufnr)
  endif
  setl modifiable

  try
    if has_key(a:resp, 'formatted') && !empty(a:resp['formatted'])
      %del
      call setline(1, split(a:resp['formatted'], '\r\?\n'))
    elseif has_key(a:resp, 'error')
      call iced#message#error_str(a:resp['error'])
    endif
  finally
    let a:finally_args['back_to_bufnr'] = current_bufnr
    call s:__format_finally(a:finally_args)
  endtry

  return iced#promise#resolve('ok')
endfunction

function! iced#format#all() abort
  if !iced#nrepl#is_connected() | return iced#message#error('not_connected') | endif

  let reg_save = @@
  let view = winsaveview()
  let codes = trim(join(getline(1, '$'), "\n"))
  if empty(codes) | return | endif

  call s:set_indentation_rule()

  let ns_name = iced#nrepl#ns#name()
  let alias_dict = iced#nrepl#ns#alias_dict(ns_name)
  let finally_args = {
        \ 'reg_save': reg_save,
        \ 'view': view,
        \ 'bufnr': bufnr('%'),
        \ 'signs': copy(iced#system#get('sign').list_in_buffer()),
        \ }

  " Disable editing until the formatting process is completed
  setl nomodifiable
  return iced#promise#call('iced#nrepl#op#iced#format_code', [codes, alias_dict])
        \.then({resp -> s:__format_all(resp, finally_args)})
        \.catch({_ -> s:__format_finally(finally_args)})
endfunction " }}}

"" iced#format#form {{{
function! s:__format_form(resp, finally_args) abort
  let current_bufnr = bufnr('%')
  if current_bufnr != a:finally_args.bufnr
    call iced#buffer#focus(a:finally_args.bufnr)
  endif
  setl modifiable

  try
    if has_key(a:resp, 'formatted') && !empty(a:resp['formatted'])
      let @@ = a:resp['formatted']
      silent normal! gvp
    elseif has_key(a:resp, 'error')
      call iced#message#error_str(a:resp['error'])
    endif
  finally
    let a:finally_args['back_to_bufnr'] = current_bufnr
    call s:__format_finally(a:finally_args)
  endtry

  return iced#promise#resolve('ok')
endfunction

function! iced#format#form() abort
  if !iced#nrepl#is_connected()
    silent exe "normal \<Plug>(sexp_indent)"
    return
  endif

  let reg_save = @@ " must be captured before get_current_top_list_raw
  let view = winsaveview() " must be captured before get_current_top_list_raw
  let codes = get(iced#paredit#get_current_top_list_raw(), 'code', '')
  if empty(codes) | return iced#message#warning('finding_code_error') | endif

  call winrestview(view)
  call s:set_indentation_rule()

  let ns_name = iced#nrepl#ns#name()
  let alias_dict = iced#nrepl#ns#alias_dict(ns_name)
  let finally_args = {
        \ 'reg_save': reg_save,
        \ 'view': view,
        \ 'bufnr': bufnr('%'),
        \ 'signs': copy(iced#system#get('sign').list_in_buffer()),
        \ }

  " Disable editing until the formatting process is completed
  setl nomodifiable
  return iced#promise#call('iced#nrepl#op#iced#format_code', [codes, alias_dict])
        \.then({resp -> s:__format_form(resp, finally_args)})
        \.catch({_ -> s:__format_finally(finally_args)})
endfunction " }}}

"" iced#format#minimal {{{
function! iced#format#minimal(...) abort
  if !iced#nrepl#is_connected()
    silent exe "normal \<Plug>(sexp_indent)"
    return
  endif

  let opt = get(a:, 1, {})
  let jump_to_its_match = get(opt, 'jump_to_its_match', v:true)

  call s:set_indentation_rule()

  let view = winsaveview()
  let reg_save = @@
  let ns_name = iced#nrepl#ns#name()
  try
    if jump_to_its_match
      " NOTE: vim-sexp's slurp move cursor to tail of form
      normal! %
    endif

    let ncol = max([col('.')-1, 0])

    let char = getline('.')[ncol]
    if char ==# '['
      silent normal! va[y
    elseif char ==# '{'
      silent normal! va{y
    else
      silent normal! va(y
    endif
    let code = @@
    let resp = iced#nrepl#op#iced#sync#format_code(code, iced#nrepl#ns#alias_dict(ns_name))
    if has_key(resp, 'formatted') && !empty(resp['formatted'])
      let @@ = iced#util#add_indent(ncol, resp['formatted'])
      silent normal! gvp
    endif
  finally
    let @@ = reg_save
    call winrestview(view)
  endtry
endfunction " }}}

"" iced#format#calculate_indent {{{
function! iced#format#calculate_indent(lnum) abort
  if !iced#nrepl#is_connected()
    return GetClojureIndent()
  endif

  call s:set_indentation_rule()

  let view = winsaveview()
  let reg_save = @@
  let ns_name = iced#nrepl#ns#name()
  try
    let res = iced#paredit#get_current_top_list()
    let code = res['code']
    if trim(code) ==# ''
      return GetClojureIndent()
    endif

    let start_line = res['curpos'][1]
    let start_column = res['curpos'][2] - 1
    let target_lnum = a:lnum - start_line

    let resp = iced#nrepl#op#iced#sync#calculate_indent_level(code, target_lnum, iced#nrepl#ns#alias_dict(ns_name))
    if has_key(resp, 'indent-level') && type(resp['indent-level']) == v:t_number && resp['indent-level'] != 0
      return resp['indent-level'] + start_column
    else
      return GetClojureIndent()
    endif
  finally
    let @@ = reg_save
    call winrestview(view)
  endtry
endfunction " }}}

"" iced#format#set_indentexpr {{{
function! iced#format#set_indentexpr() abort
  if get(g:, 'iced_enable_auto_indent', v:true)
    setlocal indentexpr=GetIcedIndent()
  endif
endfunction " }}}

let &cpo = s:save_cpo
unlet s:save_cpo
" vim:fdm=marker:fdl=0
