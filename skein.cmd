@echo off
rem The `skein` command line (D-081). build, package, run, dev and repl run natively,
rem through build\skeinc.exe, which the Phase 0 SBCL host bootstraps when it's missing or
rem older than its sources. `skein host run|dev|repl ...` runs Phase 0 itself, as a
rem reference; everything else (bootstrap, bindgen, help, version) runs on SBCL too.
setlocal
if "%SBCL%"=="" set "SBCL=sbcl"
set "HERE=%~dp0"
for %%c in (build package run dev repl) do if /i "%~1"=="%%c" goto native
if /i "%~1"=="host" goto host
"%SBCL%" --noinform --no-userinit --non-interactive --load "%HERE%host\tools\launch.lisp" --eval "(skein.cli:toplevel)" --end-toplevel-options %*
exit /b %ERRORLEVEL%

:host
rem Everything after "host": the arguments without the first.
set "ARGS="
shift
:collect
if "%~1"=="" goto run_host
set ARGS=%ARGS% %1
shift
goto collect
:run_host
"%SBCL%" --noinform --no-userinit --non-interactive --load "%HERE%host\tools\launch.lisp" --eval "(skein.cli:toplevel)" --end-toplevel-options %ARGS%
exit /b %ERRORLEVEL%

:native
set "SKEIN_HOME=%HERE:\=/%"
set "SKEINC=%HERE%build\skeinc.exe"
if not exist "%SKEINC%" goto bootstrap
"%SKEINC%" current
if errorlevel 1 goto bootstrap
goto run_native
:bootstrap
rem Bootstrapping prints what it builds; keep standard output for the program.
"%SBCL%" --noinform --no-userinit --non-interactive --load "%HERE%host\tools\launch.lisp" --eval "(skein.cli:toplevel)" --end-toplevel-options bootstrap 1>&2
if errorlevel 1 exit /b 1
:run_native
"%SKEINC%" %*
exit /b %ERRORLEVEL%
