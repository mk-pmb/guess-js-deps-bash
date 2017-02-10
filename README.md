
<!--#echo json="package.json" key="name" underline="=" -->
guess-js-deps-bash
==================
<!--/#echo -->

<!--!#echo json="package.json" key="description" -->
<!--!/#echo -->

A bash attempt at [npm-forgot](https://www.npmjs.com/package/npm-forgot):

* Guess JavaScript require() dependencies,
* detect their versions,
* compare with `package.json`.


Usage
-----

```bash
~/lib/node_modules/guess-js-deps-bash$ guess-js-deps
E: Unable to find any require()s in package: guess-js-deps-bash
```

Ok let's try some other package:

```bash
~/lib/node_modules/path-steps$ guess-js-deps tabulate-found
built-in        assert  *
built-in        path    *
relPath ./lib_demo.js   *
self-ref        path-steps      *
```

Nice TSV, but now for one with real dependencies.

```bash
~/lib/node_modules/usnam-pmb$ guess-js-deps tabulate-known
dep     clarify ^2.0.0
dep     pretty-error    ^1.1.1
```

Prefer JSON?

```javascript
~/lib/node_modules/usnam-pmb$ guess-js-deps as-json
"dependencies": {
  "clarify": "^2.0.0",
  "pretty-error": "^2.0.1"
},
"devDependencies": {},
```

How about a diff?

```diff
~/lib/node_modules/usnam-pmb$ guess-js-deps
@@ -30,5 +30,5 @@
 "dependencies": {
   "clarify": "^2.0.0",
-  "pretty-error": "^1.1.1"
+  "pretty-error": "^2.0.1"
 },
 "devDependencies": {
```

Good catch, gonna update that one right away!

```diff
~/lib/node_modules/usnam-pmb$ guess-js-deps upd
@@ -30,5 +30,5 @@
   "dependencies": {
     "clarify": "^2.0.0",
-    "pretty-error": "^1.1.1"
+    "pretty-error": "^2.0.1"
   },

patching file package.json
Using Plan A… Hunk #1 succeeded at 30.
```

Wow! Can you do that again?

```diff
~/lib/node_modules/usnam-pmb$ guess-js-deps upd
Files known.deps and found.deps are identical
```


<!--#toc stop="scan" -->



Known issues
------------

* needs more/better tests and docs




License
-------
<!--#echo json="package.json" key=".license" -->
ISC
<!--/#echo -->
