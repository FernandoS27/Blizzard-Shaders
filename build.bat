@echo off
setlocal

rem One-shot pipeline: compile every Slang permutation, then repack into
rem two BLS trees:
rem   bls_out_1_8\  — Wc3-loadable v1.8 (D3D11 SM5 + Metal, template-faithful)
rem   bls_out_1_14\ — latest v1.14 (every backend slangc produced output for,
rem                   WoW-style shaders\<stage>\<api>\ layout)
rem Forwards any extra args to compile_all_slang.py so callers can narrow
rem the sweep, e.g. `build.bat --family hd_ps --target d3d11`.

pushd "%~dp0"

py compile_all_slang.py %*
if errorlevel 1 goto :error

py build_bls.py --templates war3.w3mod\shaders --output bls_out --strip
if errorlevel 1 goto :error

popd
endlocal
exit /b 0

:error
popd
endlocal
exit /b 1
