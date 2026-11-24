# Event Mapper plugin

IDE plugin version of `src/main/resources/Event_mapper.sh`. It builds the same event map JSON,
but from the IDE's own resolved code model instead of parsing text.

## Layout

| Module | What it holds | Depends on |
|---|---|---|
| `core/` | The analysis: graph model, rules, JSON output, settings. Plain Java 17. | nothing |
| `intellij/` | The IntelliJ plugin: `PsiCodeModel` (IntelliJ's PSI and indexes → core) and the menu action. | core, IntelliJ 2022.2.4 |
| `eclipse/` | The Eclipse plug-in (a PDE project): `JdtCodeModel` (JDT search and bindings → core) and the menu command. | core (as `lib/event-mapper-core.jar`), Eclipse 2022-09+ |

The rules in `core` only see the `CodeModel` interface (`core/.../code/CodeModel.java`): "find calls
to these method names", with every argument already resolved (constant value, method-reference
target, lambda, receiver type). Each IDE implements it once; the rules are shared.

## Eclipse plug-in

1. Build core with Maven; this also copies the jar to `eclipse/lib/event-mapper-core.jar`:
   ```bash
   cd event-mapper-plugin/core && mvn package
   ```
   (Run it again after every change to core, then refresh the plug-in project in Eclipse.)
2. In Eclipse (with the Plug-in Development Environment): **File → Import → General → Existing
   Projects into Workspace**, select `event-mapper-plugin/eclipse`.
3. Try it: right-click the project → **Run As → Eclipse Application**. In the Eclipse that opens,
   import a Java project, then **Project → Export Event Map...** (or right-click projects in the
   Package Explorer). With no project selected, every open Java project is mapped.
4. Install it for real: **File → Export → Plug-in Development → Deployable plug-ins and fragments**,
   choose a directory, then copy the exported `plugins/com.eventmapper.eclipse_*.jar` into the
   `dropins/` folder of your Eclipse installation and restart.

PDE compiles against the running Eclipse, so none of this downloads anything.

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

## Install

Settings → Plugins → ⚙ → **Install Plugin from Disk…** → `intellij/build/distributions/event-mapper-0.1.0.zip`,
restart, then **Tools → Export Event Map**. Compatible with IntelliJ 2022.2 to 2024.1.

## Status

Ported from the bash analyser: components (pom.xml folders), emits, listener registrations
(method references, lambdas, unresolved handlers and events), lambdas that emit.
Still to port: listener annotations, endpoint annotations, dynamic routes, HTTP client calls,
object listeners, following plain calls, pruning, and the HTML page around the JSON.
