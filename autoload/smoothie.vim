" vim-smoothie compatibility: {command} is raw keys, e.g. "\<C-D>".
function! smoothie#do(command) abort
  call v:lua.require'smoothie'._raw(a:command)
endfunction

function! smoothie#downwards() abort
  call smoothie#do("\<C-D>")
endfunction

function! smoothie#upwards() abort
  call smoothie#do("\<C-U>")
endfunction

function! smoothie#forwards() abort
  call smoothie#do("\<C-F>")
endfunction

function! smoothie#backwards() abort
  call smoothie#do("\<C-B>")
endfunction
