# Event Mapper plugin

IDE plugin version of `src/main/resources/Event_mapper.sh`. It builds the same event map, with the
same rules and the same page, but from the IDE's own resolved code model instead of parsing text.

## Layout

| Module | What it holds | Depends on |
|---|---|---|
| `core/` | The analysis: graph model, rules, settings, JSON output, and the page (`PageRenderer`). Plain Java 17. | nothing |
| `intellij/` | The IntelliJ plugin: `PsiCodeModel` (IntelliJ's PSI and indexes → core) and the menu action. | core, IntelliJ 2022.2.4 |
| `eclipse/` | The Eclipse plug-in (a PDE project): the **Event Map view**, `JdtCodeModel` (JDT search and bindings → core) and the commands. | core (as `lib/event-mapper-core.jar`), Eclipse 2022-09+ |

The rules in `core` only see the `CodeModel` interface (`core/.../code/CodeModel.java`): find calls by
method name, methods by annotation, and the callers of a method, with every argument already resolved
by the IDE (constant value and the constants it comes from, method-reference target, lambda, receiver
and object types). Each IDE implements it once; the rules are shared.

### The page

The page lives in `Event_mapper.sh` (single source of truth). `core/extract-page.sh` copies it into
`core/src/main/resources/com/eventmapper/core/page/event-map.html`; run it after changing the page in
the script, then rebuild core. Inside an IDE the page gets clickable source locations and keeps its
view (selection, graph, zoom, moved nodes) across refreshes; in a browser it behaves as before.

## Eclipse plug-in

1. Build core with Maven; this runs its tests and copies the jar to `eclipse/lib/event-mapper-core.jar`:
   ```bash
   cd event-mapper-plugin/core && mvn package
   ```
   (Run it again after every change to core, then refresh the plug-in project in Eclipse.)
2. In Eclipse (with the Plug-in Development Environment): **File → Import → General → Existing
   Projects into Workspace**, select `event-mapper-plugin/eclipse`.
3. Try it: right-click the project → **Run As → Eclipse Application**. In the Eclipse that opens,
   import a Java project, then:
   - **Project → Show Event Map** (or right-click projects → Show Event Map, or Window → Show View →
     Other… → Event Mapper → Event Map). With no project selected, every open Java project is mapped.
   - Click a `file:line` location to open it; double-click a graph node to open its source.
   - The map refreshes by itself 1.5 s after Java files are saved, re-parsing only those files (and
     the files whose results point into them). **Refresh** (toolbar) re-analyses everything.
   - **Link with Editor** (toolbar): the method under the editor's cursor is shown in the map.
   - **Project → Export Event Map...** writes the page (`.html`) or the data (`.json`) to a file.
4. Install it for real: **File → Export → Plug-in Development → Deployable plug-ins and fragments**,
   choose a directory, then copy the exported `plugins/com.eventmapper.eclipse_*.jar` into the
   `dropins/` folder of your Eclipse installation and restart.

PDE compiles against the running Eclipse, so none of this downloads anything.

On Windows the view uses the Microsoft Edge (WebView2) browser engine: Eclipse's default engine there
is Internet Explorer, which cannot run the page. WebView2 ships with Windows 11 and recent Windows 10;
without it the view says so, and Export still works.

## IntelliJ plugin: build (in WSL, JDK 17)

The Gradle wrapper is not committed yet. Generate it once with a local Gradle 8.10.2:

```bash
cd event-mapper-plugin
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ~/tools/gradle-8.10.2/bin/gradle wrapper --gradle-version 8.10.2
```

Then:

```bash
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ./gradlew :core:test            # core tests
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 ./gradlew :intellij:buildPlugin # the plugin zip
```

The first plugin build downloads IntelliJ Community 2022.2.4 (about 700 MB).
`./gradlew :intellij:runIde` starts a sandbox IDE with the plugin installed.

Settings → Plugins → ⚙ → **Install Plugin from Disk…** → `intellij/build/distributions/event-mapper-0.1.0.zip`,
restart, then **Tools → Export Event Map**. Compatible with IntelliJ 2022.2 to 2024.1.

## Status

Rules ported from the bash analyser (in core, used by both IDEs): components (pom.xml folders), emit
calls, listener registrations (method references, lambdas, objects with callback methods, unresolved
handlers), listener annotations (event from the attributes or the first parameter's type), endpoint
annotations (verb, path with the class prefix), routes registered at run time (`addRoute`), HTTP client
calls matched to endpoints by URL, plain calls followed backwards from what emits or calls over HTTP,
and the constants (aliases included) that name each event.

The Eclipse adapter implements every query. The IntelliJ adapter only implements call search so far:
annotations and call following still need `findAnnotatedMethods` and `callersOf` in `PsiCodeModel`,
and it has no live view yet (it exports JSON).
