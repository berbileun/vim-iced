let s:save_cpo = &cpoptions
set cpoptions&vim

let s:kondo = {
      \ 'job_out': '',
      \ 'cache_dir': iced#cache#directory(),
      \ 'is_analyzing': v:false,
      \ }

function! s:user_dir() abort
  let user_dir = iced#nrepl#system#user_dir()
  if empty(user_dir)
    let user_dir = expand('%:p:h')
  endif
  return user_dir
endfunction

function! s:kondo.cache_name() abort
  return printf('%s/%s.json', self.cache_dir, substitute(s:user_dir(), '/', '_', 'g'))
endfunction

function! s:kondo.cache_temp_name() abort
  return printf('%s/.%s.tmp', self.cache_dir, substitute(s:user_dir(), '/', '_', 'g'))
endfunction

function! s:analyze__analyzed(callback, result) abort dict
  let cache_name = self.cache_name()
  call rename(self.cache_temp_name(), cache_name)

  let self.is_analyzing = v:false
  return a:callback(cache_name)
endfunction

function! s:kondo.analyze(callback) abort
  if !g:iced_enable_clj_kondo_analysis | return | endif

  if self.is_analyzing
    return a:callback({'warning': 'clj-kondo: is_analyzing'})
  endif

  let self.is_analyzing = v:true
  " NOTE: Using `writefile` will freeze vim/nvim just a little
  let command = ['sh', '-c', printf('clj-kondo --lint %s --config ''{:output {:analysis true :format :json}}'' > %s',
        \ s:user_dir(),
        \ self.cache_temp_name(),
        \ )]
  call self.job_out.redir(command, funcref('s:analyze__analyzed', [a:callback], self))
endfunction

function! s:kondo.is_analyzed() abort
  if !g:iced_enable_clj_kondo_analysis | return 0 | endif

  let cache_name = self.cache_name()
  return filereadable(cache_name)
endfunction

function! s:kondo.analysis() abort
  if !g:iced_enable_clj_kondo_analysis
    return {'error': 'clj-kondo: disabled'}
  endif

  let cache_name = self.cache_name()
  if !filereadable(cache_name)
    return {'error': printf('clj-kondo: file not readable: %s', cache_name)}
  endif

  let res = readfile(cache_name)
  if empty(res)
    return {'error': 'clj-kondo: empty file'}
  endif

  return get(json_decode(res[0]), 'analysis', {})
endfunction

function! s:kondo.references(ns_name, var_name) abort
  let ana = self.analysis()
  let usages = get(ana, 'var-usages', [])
  return filter(usages, {_, usage ->
        \ (get(usage, 'to', '') ==# a:ns_name
        \  && get(usage, 'name', '') ==# a:var_name)})
endfunction

function! s:kondo.dependencies(ns_name, var_name) abort
  let ana = self.analysis()
  let usages = get(ana, 'var-usages', [])
  let definitions = get(ana, 'var-definitions', [])
  let dependencies = filter(usages, {_, usage ->
        \ (get(usage, 'from', '') ==# a:ns_name
        \  && get(usage, 'from-var', '') ==# a:var_name
        \  && get(usage, 'to', '') !=# 'clojure.core')})
  let deps_dict = iced#util#list_to_dict(dependencies,
        \ {d -> printf('%s/%s', get(d, 'to', ''), get(d, 'name', ''))}, {d -> v:true})

  return filter(definitions, {_, definition ->
        \ has_key(deps_dict, printf('%s/%s', get(definition, 'ns', ''), get(definition, 'name', '')))})
endfunction

function! iced#component#clj_kondo#start(this) abort
  call iced#util#debug('start', 'clj-kondo')

  let s:kondo.job_out = a:this['job_out']
  return s:kondo
endfunction

let &cpoptions = s:save_cpo
unlet s:save_cpo
