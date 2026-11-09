@echo off
rem Run the `skein` command line on the Phase 0 SBCL host.
setlocal
if "%SBCL%"=="" set "SBCL=sbcl"
"%SBCL%" --noinform --no-userinit --non-interactive --load "%~dp0host\tools\launch.lisp" --eval "(skein.cli:toplevel)" --end-toplevel-options %*
exit /b %ERRORLEVEL%
