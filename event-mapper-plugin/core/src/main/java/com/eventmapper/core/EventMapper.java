package com.eventmapper.core;

import com.eventmapper.core.code.AnnotatedMethod;
import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.ConstantRef;
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
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * Builds the event map from a {@link CodeModel}, with the rules of {@code Event_mapper.sh}:
 * endpoint and listener annotations, emit calls, listener registrations (method references,
 * lambdas, objects with callback methods), routes registered at run time, HTTP client calls
 * matched to endpoints, and plain calls followed backwards from what emits or calls over HTTP.
 * IDE-independent: every fact about the code comes from the model.
 */
public final class EventMapper {

    private static final Pattern NEW_TYPE = Pattern.compile("^new\\s+([\\w.$]+)\\s*[(<]");
    private static final Pattern NAME_CHAIN = Pattern.compile("^[A-Za-z_$][\\w$]*(\\.[A-Za-z_$][\\w$]*)*$");
    private static final Pattern VERB_ARG = Pattern.compile("\\.(GET|POST|PUT|DELETE|PATCH)\\b");
    private static final Pattern VERB_RECEIVER = Pattern.compile("\\.(get|post|put|delete|patch)\\(\\)\\s*$");
    private static final Pattern VERB_NAME = Pattern.compile("^(get|post|put|delete|patch)");
    /** the verb of addRoute: an all-caps last name, {@code HttpMethod.POST} or {@code POST} */
    private static final Pattern LAST_UPPER_WORD = Pattern.compile("(?:^|\\.)([A-Z]+)$");
    private static final int MAX_FOLLOWED = 5000;

    private final MapperConfig config;

    public EventMapper(MapperConfig config) {
        this.config = config;
    }

    public Graph analyse(CodeModel code) {
        return new Run(code).run();
    }

    /** One analysis: the graph being built plus what the rules share. */
    private final class Run {
        private final CodeModel code;
        private final Graph g;
        /** how good each event label is: 3 = its constant, 2 = as written, 1 = the quoted value */
        private final Map<String, Integer> labelRank = new HashMap<>();
        private final Map<String, MethodRef> methods = new HashMap<>();
        /** endpoints with a path, for HTTP matching */
        private final List<Node> endpoints = new ArrayList<>();
        /** where events are emitted or HTTP calls made: the start of call following */
        private final Set<String> seeds = new LinkedHashSet<>();
        private int ordinal;

        Run(CodeModel code) {
            this.code = code;
            this.g = new Graph(code.rootPath(),
                    LocalDateTime.now().truncatedTo(ChronoUnit.SECONDS).format(DateTimeFormatter.ISO_LOCAL_DATE_TIME));
        }

        Graph run() {
            g.special = config.specialDirs().entrySet().stream()
                    .map(e -> e.getKey() + "=" + e.getValue()).collect(Collectors.joining(" "));
            scanTree(Path.of(code.rootPath()));

            Set<String> annotations = new LinkedHashSet<>(config.endpointAnnotations().keySet());
            annotations.addAll(config.listenAnnotations());
            for (AnnotatedMethod m : code.findAnnotatedMethods(annotations)) {
                code.checkCanceled();
                if (m.method().location() != null && !config.skipsFile(m.method().location().file())) {
                    annotated(m);
                }
            }
            // listeners and routes first: they create the lambda nodes that emits inside them belong to
            for (CallSite c : calls(config.listenMethods())) {
                listen(c);
            }
            for (CallSite c : calls(config.routeMethods())) {
                route(c);
            }
            for (CallSite c : calls(config.emitMethods())) {
                emit(c);
            }
            Set<String> clientOnly = new LinkedHashSet<>(config.clientMethods());
            clientOnly.removeAll(config.emitMethods());
            clientOnly.removeAll(config.listenMethods());
            for (CallSite c : calls(clientOnly)) {
                http(c);
            }
            if (config.followCalls()) {
                follow();
            }
            return g;
        }

        private List<CallSite> calls(Set<String> names) {
            if (names.isEmpty()) {
                return List.of();
            }
            List<CallSite> out = new ArrayList<>();
            for (CallSite c : code.findCalls(names)) {
                code.checkCanceled();
                if (c.location() != null && !config.skipsFile(c.location().file())) {
                    out.add(c);
                }
            }
            return out;
        }

        // ---- rules ----------------------------------------------------------------------

        /** {@code @GetMapping("/x")} makes an endpoint, {@code @OnEvent("x")} a handler. */
        private void annotated(AnnotatedMethod m) {
            SourceLocation at = m.method().location();
            for (AnnotatedMethod.Annotation a : m.annotations()) {
                if (config.endpointAnnotations().containsKey(a.name())) {
                    String verb = config.endpointAnnotations().get(a.name());
                    String path = firstString(a);
                    for (AnnotatedMethod.Annotation p : m.annotations()) {
                        if (path.isEmpty() && config.pathAnnotations().contains(p.name())) {
                            path = firstString(p);
                        }
                    }
                    String prefix = "";
                    for (AnnotatedMethod.Annotation p : m.classAnnotations()) {
                        if (prefix.isEmpty() && config.pathAnnotations().contains(p.name())) {
                            prefix = firstString(p);
                        }
                    }
                    Node n = method(m.method());
                    role(n, "endpoint");
                    if (!verb.isEmpty() || n.verb == null) {
                        n.verb = verb.isEmpty() ? null : verb;
                    }
                    if (!path.isEmpty() || !prefix.isEmpty()) {
                        String full = (prefix + "/" + path).replaceAll("/{2,}", "/").replaceAll("/$", "");
                        n.path = full.isEmpty() ? "/" : full;
                    }
                    if (!endpoints.contains(n)) {
                        endpoints.add(n);
                    }
                }
                if (config.listenAnnotations().contains(a.name())) {
                    List<EventRef> events = new ArrayList<>();
                    a.values().forEach((key, values) -> {
                        if (config.eventAnnotationKeys().contains(key)) {
                            for (Argument v : values) {
                                EventRef ev = namedEvent(v);
                                if (ev != null) {
                                    events.add(ev);
                                }
                            }
                        }
                    });
                    if (events.isEmpty() && m.firstParamType() != null && Character.isUpperCase(m.firstParamType().charAt(0))) {
                        events.add(byName(m.firstParamType(), m.firstParamType()));
                    }
                    Node handler = method(m.method());
                    role(handler, "handler");
                    for (EventRef ev : events) {
                        g.edge(new Edge(ev.node.id, handler.id, "handled_by", at.file(), at.line(), ev.as));
                    }
                }
            }
        }

        /** {@code bus.emit(EVENT, ...)}: where the call is written emits EVENT. */
        private void emit(CallSite c) {
            Argument arg = c.argument(0);
            if (arg == null) {
                return;
            }
            EventRef ev = namedEvent(arg);
            SourceLocation at = c.location();
            if (ev == null) {
                Node n = g.node(new Node("unres:e:" + at.file() + ":" + at.line() + ":" + (++ordinal), "event", shorten(arg.text(), 60))
                        .at(at.file(), at.line()));
                n.unres = true;
                g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), scopeId(c), shorten(callText(c), 200)));
                ev = new EventRef(n, "");
            }
            Node scope = scope(c);
            g.edge(new Edge(scope.id, ev.node.id, "emits", at.file(), at.line(), ev.as));
            seeds.add(scope.id);
        }

        /** {@code bus.subscribe(EVENT, handler)}: EVENT is handled by the handler. */
        private void listen(CallSite c) {
            if (c.arguments().size() < 2) {
                return;
            }
            EventRef ev = namedEvent(c.argument(0));
            if (ev == null) {
                return; // like the script: a registration without a readable event is not a listener
            }
            Argument h = c.argument(1);
            for (Argument a : c.arguments().subList(1, c.arguments().size())) {
                if (a.kind() == Argument.Kind.LAMBDA || a.kind() == Argument.Kind.METHOD_REFERENCE) {
                    h = a;
                    break;
                }
            }
            SourceLocation at = c.location();
            for (Node t : handlers(c, h)) {
                g.edge(new Edge(ev.node.id, t.id, "handled_by", at.file(), at.line(), ev.as));
            }
        }

        /** The nodes a listener argument resolves to. */
        private List<Node> handlers(CallSite c, Argument h) {
            SourceLocation at = c.location();
            if (h.kind() == Argument.Kind.LAMBDA && h.location() != null) {
                return List.of(lambda(h.location(), c.enclosing()));
            }
            if (h.kind() == Argument.Kind.METHOD_REFERENCE) {
                if (h.target() != null) {
                    Node n = method(h.target());
                    role(n, "handler");
                    return List.of(n);
                }
                g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), scopeId(c), "listener handler not found: " + h.text()));
                return List.of(unresolvedHandler(c, h.text(), ""));
            }
            if (h.kind() == Argument.Kind.OTHER && (h.type() != null || !h.methods().isEmpty())) {
                List<Node> out = new ArrayList<>();
                for (MethodRef m : h.methods()) {
                    if (config.callbackMethods().contains(m.name())) {
                        out.add(method(m));
                    }
                }
                boolean anonymous = h.text().startsWith("new") && h.text().contains("{");
                if (out.isEmpty() && anonymous && h.methods().size() == 1) {
                    out.add(method(h.methods().get(0)));
                }
                out.forEach(n -> role(n, "handler"));
                if (out.isEmpty() && h.type() != null && h.text().startsWith("new")) {
                    out.add(classNode(h.type()));
                }
                if (!out.isEmpty()) {
                    return out;
                }
            }
            g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), scopeId(c),
                    "handler not resolved, shown at registration site: " + shorten(callText(c), 160)));
            return List.of(unresolvedHandler(c, h.text(), ""));
        }

        /** {@code router.addRoute(VERB, name, handler)}: an endpoint "Lambda &lt;method&gt;" calling the handler. */
        private void route(CallSite c) {
            if (c.arguments().size() < 3) {
                return;
            }
            SourceLocation at = c.location();
            Matcher vm = LAST_UPPER_WORD.matcher(c.argument(0).text().trim());
            String verb = vm.find() ? vm.group(1) : "ANY";
            Argument name = c.argument(1);
            String path = name.constant() != null ? name.constant() : "{" + shorten(name.text(), 60) + "}";
            String own = c.enclosing() != null ? c.enclosing().name() : fileName(at.file());
            Node ep = g.node(new Node("route:" + at.file() + ":" + at.line() + ":" + (++ordinal), "endpoint", "Lambda " + own)
                    .at(at.file(), at.line()));
            ep.cls = c.enclosing() == null ? "" : c.enclosing().className();
            ep.verb = verb;
            ep.path = path;
            ep.addRole("lambda");
            endpoints.add(ep);

            Argument h = c.argument(2);
            Node target;
            if (h.kind() == Argument.Kind.LAMBDA && h.location() != null) {
                target = lambda(h.location(), c.enclosing());
            } else if (h.kind() == Argument.Kind.METHOD_REFERENCE && h.target() != null) {
                target = method(h.target());
            } else {
                g.unresolved.add(new Graph.Unresolved(at.file(), at.line(), "", "route handler not found: " + shorten(h.text(), 160)));
                target = unresolvedHandler(c, h.text(), ":r" + ordinal);
            }
            g.edge(new Edge(ep.id, target.id, "calls", at.file(), at.line(), ""));
        }

        /** {@code restTemplate.postForObject("/orders", ..)}: calls the endpoint with that path. */
        private void http(CallSite c) {
            String verb = "";
            for (Argument a : c.arguments()) {
                Matcher m = VERB_ARG.matcher(a.text());
                if (m.find()) {
                    verb = m.group(1);
                    break;
                }
            }
            if (verb.isEmpty() && "uri".equals(c.methodName()) && c.receiver() != null) {
                Matcher m = VERB_RECEIVER.matcher(c.receiver());
                if (m.find()) {
                    verb = m.group(1).toUpperCase();
                }
            }
            if (verb.isEmpty()) {
                Matcher m = VERB_NAME.matcher(c.methodName());
                if (m.find()) {
                    verb = m.group(1).toUpperCase();
                }
            }
            String url = null;
            for (Argument a : c.arguments()) {
                String v = a.stringValue();
                if (v != null && v.contains("/")) {
                    url = v;
                    break;
                }
            }
            if (url == null) {
                return;
            }
            List<Node> targets = matchUrl(url, verb);
            if (targets.isEmpty()) {
                return;
            }
            Node scope = scope(c);
            for (Node t : targets) {
                g.edge(new Edge(scope.id, t.id, "http", c.location().file(), c.location().line(), ""));
            }
            seeds.add(scope.id);
        }

        /** Plain calls, followed backwards from what emits or calls over HTTP, so chains connect. */
        private void follow() {
            Deque<MethodRef> queue = new ArrayDeque<>();
            Set<String> seen = new HashSet<>();
            for (String id : seeds) {
                MethodRef m = methods.get(id);
                if (m != null && seen.add(id)) {
                    queue.add(m);
                }
            }
            while (!queue.isEmpty() && seen.size() < MAX_FOLLOWED) {
                code.checkCanceled();
                MethodRef callee = queue.poll();
                for (CallSite c : code.callersOf(callee)) {
                    if (c.location() == null || config.skipsFile(c.location().file())) {
                        continue;
                    }
                    Node scope = scope(c);
                    if (scope.id.equals(callee.id())) {
                        continue; // recursion
                    }
                    g.edge(new Edge(scope.id, callee.id(), "calls", c.location().file(), c.location().line(), ""));
                    MethodRef caller = methods.get(scope.id);
                    if (caller != null && seen.add(scope.id)) {
                        queue.add(caller);
                    }
                }
            }
        }

        // ---- events ---------------------------------------------------------------------

        private record EventRef(Node node, String as) {
        }

        /**
         * The event an argument names, as the script reads it: a String constant gives its value; an
         * event class ({@code new OrderCreated(..)}, {@code OrderCreated.class}) or another constant-like
         * reference ({@code Type.ORDER_CREATED}) gives its last name; anything else gives null.
         */
        private EventRef namedEvent(Argument a) {
            if (a == null) {
                return null;
            }
            if (a.kind() == Argument.Kind.CONSTANT && a.constant() != null) {
                return constantEvent(a);
            }
            String text = a.text().trim();
            Matcher nm = NEW_TYPE.matcher(text);
            if (nm.find()) {
                String simple = last(nm.group(1));
                return byName(simple, simple);
            }
            if (NAME_CHAIN.matcher(text).matches()) {
                String ref = text.endsWith(".class") ? text.substring(0, text.length() - 6) : text;
                if (Character.isUpperCase(ref.charAt(0)) || ref.matches(".*\\.[A-Z].*")) {
                    return byName(last(ref), ref);
                }
            }
            return null;
        }

        private EventRef constantEvent(Argument a) {
            String value = a.constant();
            List<ConstantRef> refs = a.refs();
            String label;
            int rank;
            if (!refs.isEmpty()) {
                label = refs.get(refs.size() - 1).name();
                rank = 3;
            } else if (a.literal()) {
                label = "\"" + value + "\"";
                rank = 1;
            } else {
                label = a.text();
                rank = 2;
            }
            Node n = event(value, label, rank);
            if (rank == 3) {
                SourceLocation decl = refs.get(refs.size() - 1).location();
                if (decl != null && n.file == null) {
                    n.at(decl.file(), decl.line());
                }
            }
            for (int i = 0; i < refs.size(); i++) {
                ConstantRef r = refs.get(i);
                String to = i + 1 < refs.size() ? refs.get(i + 1).name() : null;
                if (n.aka.stream().noneMatch(k -> k.name().equals(r.name()))) {
                    n.aka.add(new Node.Aka(r.name(), to, r.location() == null ? "" : r.location().file(),
                            r.location() == null ? 0 : r.location().line(), false));
                }
            }
            // like the script, the name written in the code is kept only when an alias was followed
            return new EventRef(n, refs.size() > 1 ? refs.get(0).name() : "");
        }

        private EventRef byName(String name, String label) {
            return new EventRef(event(name, label, 2), "");
        }

        private Node event(String value, String label, int rank) {
            Node n = g.node(new Node("event:" + value, "event", label));
            n.value = value;
            if (rank > labelRank.getOrDefault(n.id, 0)) {
                n.label = label;
                labelRank.put(n.id, rank);
            }
            return n;
        }

        // ---- nodes ----------------------------------------------------------------------

        /** Where a call is written: its lambda when that lambda is a handler, else its method, else its file. */
        private Node scope(CallSite c) {
            if (c.lambda() != null) {
                Node l = g.get(lambdaId(c.lambda()));
                if (l != null) {
                    return l;
                }
            }
            if (c.enclosing() != null) {
                return method(c.enclosing());
            }
            String f = c.location().file();
            return g.node(new Node("file:" + f, "class", fileName(f)).at(f, 1));
        }

        private String scopeId(CallSite c) {
            return c.enclosing() == null ? c.location().file() : c.enclosing().label();
        }

        private Node method(MethodRef m) {
            Node n = g.node(new Node(m.id(), "method", m.label()));
            methods.putIfAbsent(n.id, m);
            n.cls = m.className();
            if (m.location() != null && n.file == null) {
                n.at(m.location().file(), m.location().line());
            }
            return n;
        }

        /** Adds a role; a method that is an endpoint shows as one, else as a handler if it handles events. */
        private void role(Node n, String role) {
            n.addRole(role);
            if (n.kind.equals("method") || n.kind.equals("handler")) {
                n.kind = n.roles.contains("endpoint") ? "endpoint" : n.roles.contains("handler") ? "handler" : n.kind;
            }
        }

        private Node classNode(String type) {
            Node n = g.node(new Node("class:" + type, "class", last(type)));
            n.cls = type;
            return n;
        }

        private String lambdaId(SourceLocation at) {
            return "lambda:" + at.file() + ":" + at.line();
        }

        private Node lambda(SourceLocation at, MethodRef in) {
            String label = "λ in " + (in == null ? at.file() : in.label()) + " (L" + at.line() + ")";
            Node n = g.node(new Node(lambdaId(at), "lambda", label).at(at.file(), at.line()));
            n.cls = in == null ? "" : in.className();
            return n;
        }

        private Node unresolvedHandler(CallSite c, String text, String suffix) {
            SourceLocation at = c.location();
            Node n = g.node(new Node("unres:h:" + at.file() + ":" + at.line() + suffix, "handler",
                    text == null || text.isBlank() ? "unknown handler" : shorten(text, 60)).at(at.file(), at.line()));
            n.unres = true;
            n.cls = c.enclosing() == null ? "" : c.enclosing().className();
            return n;
        }

        // ---- HTTP matching --------------------------------------------------------------

        /**
         * Endpoints whose path ends the URL, segment by segment ({..} on either side is a wildcard, at
         * least one literal segment must match); only the best-scoring ones are kept.
         */
        private List<Node> matchUrl(String url, String verb) {
            String u = url.replaceFirst("^[a-zA-Z]+://[^/]*", "").replaceFirst("[?#].*", "");
            List<String> cs = segments(u);
            List<Node> best = new ArrayList<>();
            int bestScore = 0;
            for (Node ep : endpoints) {
                if (ep.path == null || ep.path.startsWith("{")) {
                    continue;
                }
                if (!verb.isEmpty() && ep.verb != null && !ep.verb.equals("ANY") && !ep.verb.equals(verb)) {
                    continue;
                }
                List<String> es = segments(ep.path);
                int ne = es.size(), nc = cs.size();
                if (ne == 0 || ne > nc) {
                    continue;
                }
                int lit = 0;
                boolean ok = true;
                for (int j = 0; j < ne; j++) {
                    String c1 = cs.get(nc - ne + j), e1 = es.get(j);
                    if (c1.contains("{") || e1.contains("{")) {
                        continue;
                    }
                    if (!c1.equals(e1)) {
                        ok = false;
                        break;
                    }
                    lit++;
                }
                if (!ok || lit == 0) {
                    continue;
                }
                int score = lit * 10 - (nc - ne);
                if (score > bestScore) {
                    bestScore = score;
                    best.clear();
                    best.add(ep);
                } else if (score == bestScore) {
                    best.add(ep);
                }
            }
            return best;
        }

        private List<String> segments(String path) {
            List<String> out = new ArrayList<>();
            for (String s : path.split("/")) {
                if (!s.isEmpty()) {
                    out.add(s);
                }
            }
            return out;
        }

        // ---- file tree ------------------------------------------------------------------

        /** Counts the Java files and lists the components (folders with a pom.xml), as the script does. */
        private void scanTree(Path root) {
            if (!Files.isDirectory(root)) {
                return;
            }
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
                            String name = isRoot ? String.valueOf(root.getFileName()) : dir.getFileName().toString();
                            g.components.add(new Graph.Component(rel, name));
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
        }
    }

    // ---- text helpers -----------------------------------------------------------------------

    /** The first String value of an annotation: "value", then "path", then any attribute. */
    private static String firstString(AnnotatedMethod.Annotation a) {
        for (String key : List.of("value", "path")) {
            for (Argument v : a.values().getOrDefault(key, List.of())) {
                if (v.stringValue() != null) {
                    return v.stringValue();
                }
            }
        }
        for (List<Argument> vs : a.values().values()) {
            for (Argument v : vs) {
                if (v.stringValue() != null) {
                    return v.stringValue();
                }
            }
        }
        return "";
    }

    private static String callText(CallSite c) {
        return (c.receiver() == null ? "" : c.receiver() + ".") + c.methodName() + "("
                + c.arguments().stream().map(Argument::text).collect(Collectors.joining(", ")) + ")";
    }

    private static String last(String dotted) {
        return dotted.substring(dotted.lastIndexOf('.') + 1);
    }

    private static String fileName(String path) {
        return path.substring(path.lastIndexOf('/') + 1);
    }

    private static String shorten(String s, int max) {
        String t = s == null ? "" : s.replaceAll("\\s+", " ").trim();
        return t.length() > max ? t.substring(0, max - 3) + "..." : t;
    }
}
