package com.eventmapper.core;

import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import com.eventmapper.core.model.Edge;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/**
 * Builds the event map from a {@link CodeModel}. IDE-independent: every fact about the code
 * comes from the model.
 *
 * <p>Ported so far: components (pom.xml folders), emits and listener registrations
 * (method references, lambdas, unresolved handlers). Still to port from the bash analyser:
 * listener annotations, endpoint annotations, dynamic routes, HTTP client calls, object
 * listeners (callback methods), following plain calls, and pruning.
 */
public final class EventMapper {

    private final MapperConfig config;

    public EventMapper(MapperConfig config) {
        this.config = config;
    }

    public Graph analyse(CodeModel code) {
        Graph g = new Graph(code.rootPath(),
                LocalDateTime.now().truncatedTo(ChronoUnit.SECONDS).format(DateTimeFormatter.ISO_LOCAL_DATE_TIME));
        g.special = config.specialDirs().entrySet().stream()
                .map(e -> e.getKey() + "=" + e.getValue()).collect(Collectors.joining(" "));
        scanTree(Path.of(code.rootPath()), g);

        for (CallSite c : code.findCalls(config.emitMethods())) {
            code.checkCanceled();
            emit(g, c);
        }
        for (CallSite c : code.findCalls(config.listenMethods())) {
            code.checkCanceled();
            listen(g, c);
        }
        return g;
    }

    // ---- rules --------------------------------------------------------------------------

    /** {@code bus.emit(EVENT, ...)}: the scope of the call emits EVENT. */
    private void emit(Graph g, CallSite c) {
        Argument ev = c.argument(0);
        if (ev == null) {
            return;
        }
        Node event = event(g, c, ev);
        g.edge(new Edge(scope(g, c).id, event.id, "emits", c.location().file(), c.location().line(), ev.text()));
    }

    /** {@code bus.subscribe(EVENT, handler)}: EVENT is handled by the last argument. */
    private void listen(Graph g, CallSite c) {
        if (c.arguments().size() < 2) {
            return;
        }
        Argument ev = c.argument(0);
        Argument h = c.argument(c.arguments().size() - 1);
        Node event = event(g, c, ev);
        Node handler;
        if (h.kind() == Argument.Kind.LAMBDA) {
            handler = lambda(g, h.location(), c.enclosing());
        } else if (h.kind() == Argument.Kind.METHOD_REFERENCE && h.target() != null) {
            handler = method(g, h.target());
            handler.addRole("handler");
            if (!"endpoint".equals(handler.kind)) {
                handler.kind = "handler";
            }
        } else {
            SourceLocation at = c.location();
            handler = g.node(new Node("unres:h:" + at.file() + ":" + at.line(), "handler", h.text()).at(at.file(), at.line()));
            handler.unres = true;
            handler.cls = c.enclosing() == null ? "" : c.enclosing().className();
            g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), scopeLabel(c), "handler " + h.text()));
        }
        g.edge(new Edge(event.id, handler.id, "handled_by", c.location().file(), c.location().line(), ev.text()));
    }

    // ---- nodes --------------------------------------------------------------------------

    /** The event an argument names: by constant value when known, else an unresolved event at the call. */
    private Node event(Graph g, CallSite c, Argument a) {
        if (a.kind() == Argument.Kind.CONSTANT) {
            // labelled as written: a quoted string for a literal, the reference otherwise
            String label = a.literal() ? "\"" + a.constant() + "\"" : a.text();
            Node n = g.node(new Node("event:" + a.constant(), "event", label));
            n.value = a.constant();
            if (!n.label.equals(label) && !n.aka.contains(label)) {
                n.aka.add(label);
            }
            return n;
        }
        SourceLocation at = c.location();
        int i = c.arguments().indexOf(a);
        Node n = g.node(new Node("unres:e:" + at.file() + ":" + at.line() + ":" + i, "event", a.text()).at(at.file(), at.line()));
        n.unres = true;
        g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), scopeLabel(c), "event " + a.text()));
        return n;
    }

    /** Where a call is written: its innermost lambda, else its method, else its file. */
    private Node scope(Graph g, CallSite c) {
        if (c.lambda() != null) {
            return lambda(g, c.lambda(), c.enclosing());
        }
        if (c.enclosing() != null) {
            return method(g, c.enclosing());
        }
        String f = c.location().file();
        return g.node(new Node("file:" + f, "class", f.substring(f.lastIndexOf('/') + 1)).at(f, 1));
    }

    private Node method(Graph g, MethodRef m) {
        Node n = g.node(new Node(m.id(), "method", m.label()));
        n.cls = m.className();
        if (m.location() != null && n.file == null) {
            n.at(m.location().file(), m.location().line());
        }
        return n;
    }

    private Node lambda(Graph g, SourceLocation at, MethodRef in) {
        String label = "λ in " + (in == null ? at.file() : in.label()) + " (L" + at.line() + ")";
        Node n = g.node(new Node("lambda:" + at.file() + ":" + at.line(), "lambda", label).at(at.file(), at.line()));
        n.cls = in == null ? "" : in.className();
        return n;
    }

    private static String scopeLabel(CallSite c) {
        return c.enclosing() == null ? c.location().file() : c.enclosing().label();
    }

    // ---- file tree ----------------------------------------------------------------------

    /** Counts the Java files and lists the components (folders with a pom.xml), as the script does. */
    private void scanTree(Path root, Graph g) {
        if (!Files.isDirectory(root)) {
            return;
        }
        List<Graph.Component> found = new ArrayList<>();
        int[] files = {0};
        try {
            Files.walkFileTree(root, new SimpleFileVisitor<>() {
                @Override
                public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) {
                    boolean isRoot = dir.equals(root);
                    if (!isRoot && config.skips(dir.getFileName().toString())) {
                        return FileVisitResult.SKIP_SUBTREE;
                    }
                    if (Files.isRegularFile(dir.resolve("pom.xml"))) {
                        String rel = isRoot ? "" : root.relativize(dir).toString().replace('\\', '/');
                        found.add(new Graph.Component(rel, isRoot ? root.getFileName().toString() : dir.getFileName().toString()));
                    }
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) {
                    if (file.getFileName().toString().endsWith(".java")) {
                        files[0]++;
                    }
                    return FileVisitResult.CONTINUE;
                }

                @Override
                public FileVisitResult visitFileFailed(Path file, IOException e) {
                    return FileVisitResult.CONTINUE;
                }
            });
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        g.files = files[0];
        g.components.addAll(found);
    }
}
