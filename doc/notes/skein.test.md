Unit tests in the style of clojure.test. A project keeps them in `test/`, one namespace a file, and `skein test` runs them natively, exiting with 1 on a failure:

```skein
(ns game.physics-test
  (:require [skein.test :refer [deftest is testing]]
            [game.physics :as physics]))

(deftest falling
  (testing "gravity pulls down"
    (is (neg? (:vy (physics/step {:vy 0.0} 0.1))))))
```

## deftest
### Arguments and values
- `test-name`: a symbol.
- `body`: assertions (`is`, `are`) and any code.
- Defines a function of no arguments that runs the body as a test, registers it with the namespace, and returns the name.

### Notes
Defining a test again keeps its place in the order. An error the body signals outside an `is` is reported as an error of the test.

See also: is, run-tests, testing

## is
### Arguments and values
- `form`: what should be true; or `(thrown? type body...)`, or `(thrown-with-msg? type text body...)`.
- `message`: an optional string for a failure's report.
- Returns the form's value (the condition, for `thrown?`).

### Notes
For a call of a function, a failure reports the call with its arguments' values, `(not (= 5 4))`, so you see what was compared.

See also: are, testing, deftest

## are
### Arguments and values
- `argv`: a vector of symbols.
- `expr`: an expression using them.
- `values`: groups of as many values, one `is` each.

See also: is

## testing
### Arguments and values
- `description`: a string, added to what failures inside report.
- `body`: assertions.
- Returns the body's value.

See also: is, deftest

## run-tests
### Arguments and values
- `namespaces`: names, symbols or strings.
- Runs their tests in the order they were defined, with their fixtures, and prints a report.
- Returns the counts, `{:test :pass :fail :error}`.

See also: successful?, test-ns, deftest

## successful?
### Arguments and values
- `counts`: what `run-tests` returned.
- Returns true if there were no failures and no errors.

See also: run-tests

## use-fixtures
### Arguments and values
- `kind`: `:each`, around each test, or `:once`, around all of them.
- `fs`: functions of a function of no arguments, which they call to run the tests.
- Replaces this namespace's fixtures of that kind.

### Notes
A fixture sets up, calls its argument, then cleans up, as `with-open` would: `(fn [run] (let [dir (io/temp-dir)] (try (run) (finally (io/delete-tree dir)))))`.

See also: set-fixtures!, deftest

## set-fixtures!
### Arguments and values
- `ns-name`: a namespace's name, a string.
- `kind`: `:each` or `:once`.
- `fs`: a vector of fixtures.
- What `use-fixtures` calls.

See also: use-fixtures

## test-ns
### Arguments and values
- `ns-name`: a namespace's name, a string.
- Runs its tests inside its fixtures, without printing a report; they count in `*counters*` if it is bound.

See also: run-tests

## *counters*
### Arguments and values
- A dynamic var: an atom of `{:test :pass :fail :error}` while `run-tests` runs, else nil.

See also: run-tests, report-pass

## *testing-names*
### Arguments and values
- A dynamic var: the names of the tests running, outermost first, as failures report them.

See also: deftest

## *testing-contexts*
### Arguments and values
- A dynamic var: the descriptions of the `testing` forms around the code running, outermost first.

See also: testing

## message-has?
### Arguments and values
- `message`: a string.
- `part`: a string.
- Returns true if `message` contains `part`.

See also: is, skein.string/includes?

## register-test!
### Arguments and values
- `ns-name`: a namespace's name, a string.
- `test-name`: a symbol.
- `f`: a function of no arguments that runs the test.
- What `deftest` calls; for tests generated at run time.

See also: deftest, run-test-body

## run-test-body
### Arguments and values
- `test-name`: a symbol.
- `body`: a function of no arguments.
- Counts the test, runs the body and reports an error it signals. Returns nil.

See also: register-test!

## report-pass
### Arguments and values
- Counts a passing assertion; for assertions of your own.

See also: report-fail, report-error

## report-fail
### Arguments and values
- `message`: a string, or nil.
- `expected`: the assertion, as data.
- `actual`: what was found.
- Counts and prints a failure.

See also: report-pass, report-error

## report-error
### Arguments and values
- `message`: a string, or nil.
- `expected`: the assertion, or nil.
- `c`: the condition signaled.
- Counts and prints an error.

See also: report-fail

