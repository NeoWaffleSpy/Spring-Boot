# Event Mapper plugin

IDE plugin version of `src/main/resources/Event_mapper.sh`. It builds the same event map JSON,
but from the IDE's own resolved code model instead of parsing text.

## Layout

| Module | What it holds | Depends on |
|---|---|---|
| `core/` | The analysis: graph model, rules, JSON output, settings. Plain Java 17. | nothing |
| `intellij/` | The IntelliJ plugin: `PsiCodeModel` (IntelliJ's PSI and indexes → core) and the menu action. | core, IntelliJ 2022.2.4 |

The rules in `core` only see the `CodeModel` interface (`core/.../code/CodeModel.java`): "find calls
to these method names", with every argument already resolved (constant value, method-reference
target, lambda, receiver type). Each IDE implements it once; the rules are shared.

### Adding Eclipse later

Add an `eclipse/` adapter that implements `CodeModel` with JDT (`SearchEngine` to find calls,
`resolveMethodBinding()` / `resolveConstantExpressionValue()` to resolve them) plus a menu command.
Eclipse plugins are OSGi bundles, usually built with Maven Tycho: `core` will need an OSGi
manifest (for example with the `biz.aQute.bnd.builder` Gradle plugin) or be embedded in the
Eclipse bundle's jar.

## Build (in WSL, JDK 17)

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
