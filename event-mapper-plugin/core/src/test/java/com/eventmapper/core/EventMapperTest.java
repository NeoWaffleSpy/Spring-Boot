package com.eventmapper.core;

import com.eventmapper.core.code.AnnotatedMethod;
import com.eventmapper.core.code.AnnotatedMethod.Annotation;
import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.ConstantRef;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Edge;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class EventMapperTest {

    private static final String SVC = "shop/src/main/java/com/shop/OrderService.java";
    private static final String API = "shop/src/main/java/com/shop/OrderController.java";
    private static final String EVT = "shop/src/main/java/com/shop/Events.java";
    private static final String BILL = "billing/src/main/java/com/bill/BillingClient.java";
    private static final MethodRef CREATE = m("com.shop.OrderService", "create", SVC, 10);
    private static final MethodRef INIT = m("com.shop.OrderService", "init", SVC, 20);
    private static final MethodRef SAVE = m("com.shop.OrderController", "save", API, 15);
    private static final MethodRef ON_CREATED = m("com.shop.Mailer", "onCreated", "shop/src/main/java/com/shop/Mailer.java", 5);
    private static final ConstantRef CREATED = new ConstantRef("Events.CREATED", loc(EVT, 3));
    private static final ConstantRef NEW_ORDER = new ConstantRef("Events.NEW_ORDER", loc(EVT, 4));

    private String rootPath;
    private final List<CallSite> calls = new ArrayList<>();
    private final List<AnnotatedMethod> annotated = new ArrayList<>();
    private final List<CallSite> callers = new ArrayList<>();

    /** A code model answering from fixed lists, standing in for an IDE. */
    private final CodeModel model = new CodeModel() {
        @Override
        public String rootPath() {
            return rootPath;
        }

        @Override
        public List<CallSite> findCalls(Set<String> names) {
            return calls.stream().filter(c -> names.contains(c.methodName())).toList();
        }

        @Override
        public List<AnnotatedMethod> findAnnotatedMethods(Set<String> names) {
            return annotated.stream().filter(m -> m.annotations().stream().anyMatch(a -> names.contains(a.name()))).toList();
        }

        @Override
        public List<CallSite> callersOf(MethodRef method) {
            return callers.stream().filter(c -> c.methodName().equals(method.name())).toList();
        }
    };

    private static MethodRef m(String cls, String name, String file, int line) {
        return new MethodRef(cls, cls.substring(cls.lastIndexOf('.') + 1), name, loc(file, line));
    }

    private static SourceLocation loc(String f, int l) {
        return new SourceLocation(f, l);
    }

    private static CallSite call(String name, MethodRef in, SourceLocation at, Argument... args) {
        return new CallSite(name, null, null, List.of(args), in, null, at);
    }

    private static Annotation ann(String name, Map<String, List<Argument>> values) {
        return new Annotation(name, values);
    }

    @BeforeEach
    void tree(@TempDir Path root) throws IOException {
        Files.createDirectories(root.resolve("shop/src/main/java/com/shop"));
        Files.createDirectories(root.resolve("billing/target/generated"));
        Files.writeString(root.resolve("pom.xml"), "<project/>");
        Files.writeString(root.resolve("shop/pom.xml"), "<project/>");
        Files.writeString(root.resolve("billing/pom.xml"), "<project/>");
        Files.writeString(root.resolve(SVC), "class OrderService {}");
        Files.writeString(root.resolve("billing/target/generated/Gen.java"), "class Gen {}");
        rootPath = root.toString().replace('\\', '/');
    }

    private Graph analyse() {
        return new EventMapper(MapperConfig.defaults()).analyse(model);
    }

    @Test
    void emitsAndListenersThroughConstantsAndAliases() {
        // bus.emit(Events.NEW_ORDER) where NEW_ORDER = CREATED = "order.created"
        calls.add(call("emit", CREATE, loc(SVC, 12), Argument.constant("Events.NEW_ORDER", "order.created", false, List.of(NEW_ORDER, CREATED))));
        // bus.subscribe("order.created", mailer::onCreated)
        calls.add(call("subscribe", INIT, loc(SVC, 21), Argument.constant("\"order.created\"", "order.created", true),
                Argument.methodReference("mailer::onCreated", ON_CREATED)));
        Graph g = analyse();

        Node ev = g.get("event:order.created");
        assertEquals("Events.CREATED", ev.label, "named after the constant holding the value");
        assertEquals(EVT, ev.file);
        assertEquals(List.of(new Node.Aka("Events.NEW_ORDER", "Events.CREATED", EVT, 4, false),
                new Node.Aka("Events.CREATED", null, EVT, 3, false)), ev.aka);
        assertTrue(g.edges().contains(new Edge(CREATE.id(), ev.id, "emits", SVC, 12, "Events.NEW_ORDER")), "alias kept as 'as'");
        assertTrue(g.edges().contains(new Edge(ev.id, ON_CREATED.id(), "handled_by", SVC, 21, "")));
        assertEquals("handler", g.get(ON_CREATED.id()).kind);
    }

    @Test
    void eventClassesLambdasObjectsAndUnresolved() {
        SourceLocation lam = loc(SVC, 22);
        calls.add(call("subscribe", INIT, lam, Argument.other("OrderPaid.class"), Argument.lambda("e -> ship(e)", lam)));
        calls.add(new CallSite("fire", null, null, List.of(Argument.other("new OrderShipped(o)")), INIT, lam, loc(SVC, 23)));
        MethodRef handle = m("com.shop.Audit", "handle", "shop/src/main/java/com/shop/Audit.java", 8);
        MethodRef other = m("com.shop.Audit", "toString", "shop/src/main/java/com/shop/Audit.java", 12);
        calls.add(call("subscribe", INIT, loc(SVC, 24), Argument.other("Type.ORDER_SHIPPED"),
                Argument.other("audit", null, "com.shop.Audit", List.of(handle, other))));
        calls.add(call("emit", CREATE, loc(SVC, 14), Argument.other("name")));
        calls.add(call("subscribe", INIT, loc(SVC, 25), Argument.constant("\"x\"", "x", true), Argument.other("handlers.get(0)")));
        Graph g = analyse();

        String lambda = "lambda:" + SVC + ":22";
        assertTrue(g.edges().contains(new Edge("event:OrderPaid", lambda, "handled_by", SVC, 22, "")));
        assertTrue(g.edges().contains(new Edge(lambda, "event:OrderShipped", "emits", SVC, 23, "")), "emitted inside the handler lambda");
        assertEquals("Type.ORDER_SHIPPED", g.get("event:ORDER_SHIPPED").label);
        assertTrue(g.edges().contains(new Edge("event:ORDER_SHIPPED", handle.id(), "handled_by", SVC, 24, "")), "callback method of the object");
        assertNull(g.get(other.id()));
        Node unknownEvent = g.nodes().stream().filter(n -> n.id.startsWith("unres:e:")).findFirst().orElseThrow();
        assertTrue(unknownEvent.unres);
        Node unknownHandler = g.get("unres:h:" + SVC + ":25");
        assertTrue(unknownHandler.unres);
        assertEquals(2, g.unresolved.size());
    }

    @Test
    void endpointsRoutesHttpCallsAndFollowedCalls() {
        // @RequestMapping("/api") class OrderController { @PostMapping("orders/{id}") void save(OrderEvent e) }
        annotated.add(new AnnotatedMethod(SAVE,
                List.of(ann("PostMapping", Map.of("value", List.of(Argument.constant("\"orders/{id}\"", "orders/{id}", true))))),
                List.of(ann("RequestMapping", Map.of("value", List.of(Argument.constant("\"/api/\"", "/api/", true))))), "OrderEvent"));
        // @EventListener void on(OrderCreated e)
        MethodRef on = m("com.shop.Listeners", "on", "shop/src/main/java/com/shop/Listeners.java", 9);
        annotated.add(new AnnotatedMethod(on, List.of(ann("EventListener", Map.of())), List.of(), "OrderCreated"));
        // router.addRoute(HttpMethod.POST, endpointName, (o, event) -> bus.emit("routed"))
        SourceLocation lam = loc(SVC, 31);
        calls.add(call("addRoute", INIT, loc(SVC, 30), Argument.other("HttpMethod.POST"), Argument.other("endpointName"),
                Argument.lambda("(o, event) -> bus.emit(\"routed\")", lam)));
        calls.add(new CallSite("emit", null, null, List.of(Argument.constant("\"routed\"", "routed", true)), INIT, lam, loc(SVC, 31)));
        // in billing: restTemplate.postForObject(BASE + "/orders/" + id, ...) inside BillingClient.bill()
        MethodRef bill = m("com.bill.BillingClient", "bill", BILL, 7);
        calls.add(call("postForObject", bill, loc(BILL, 9), Argument.other("BASE + \"/orders/\" + id", "http://shop/api/orders/{}", null, List.of()), Argument.other("body")));
        calls.add(call("emit", bill, loc(BILL, 10), Argument.constant("\"billed\"", "billed", true)));
        // a call in a skipped folder is ignored
        calls.add(call("emit", bill, loc("billing/out/Gen.java", 1), Argument.constant("\"ghost\"", "ghost", true)));
        // BillingJob.run() calls bill(), so the chain connects
        MethodRef run = m("com.bill.BillingJob", "run", "billing/src/main/java/com/bill/BillingJob.java", 4);
        callers.add(call("bill", run, loc("billing/src/main/java/com/bill/BillingJob.java", 5)));
        Graph g = analyse();

        Node save = g.get(SAVE.id());
        assertEquals("endpoint", save.kind);
        assertEquals("/api/orders/{id}", save.path);
        assertEquals("POST", save.verb);
        assertTrue(g.edges().contains(new Edge("event:OrderCreated", on.id(), "handled_by", on.location().file(), 9, "")));

        Node route = g.nodes().stream().filter(n -> n.id.startsWith("route:")).findFirst().orElseThrow();
        assertEquals("Lambda init", route.label);
        assertEquals("POST", route.verb);
        assertEquals("{endpointName}", route.path);
        assertEquals(List.of("lambda"), route.roles);
        assertTrue(g.edges().contains(new Edge(route.id, "lambda:" + SVC + ":31", "calls", SVC, 30, "")));
        assertTrue(g.edges().contains(new Edge("lambda:" + SVC + ":31", "event:routed", "emits", SVC, 31, "")));

        assertTrue(g.edges().contains(new Edge(bill.id(), SAVE.id(), "http", BILL, 9, "")), "URL matched to the endpoint");
        assertTrue(g.edges().contains(new Edge(run.id(), bill.id(), "calls", "billing/src/main/java/com/bill/BillingJob.java", 5, "")));
        assertNull(g.get("event:ghost"));

        assertEquals(1, g.files, "billing/target is scanned (special), billing/out would not be");
        assertEquals(List.of("", "billing", "shop"), g.components.stream().map(Graph.Component::dir).sorted().toList());

        String json = GraphJsonWriter.write(g);
        assertTrue(json.contains("\"verb\":\"POST\""));
        assertFalse(json.contains("\"aka\":[\""));
    }

    @Test
    void jsonMatchesThePageFormat() {
        calls.add(call("emit", CREATE, loc(SVC, 12), Argument.constant("Events.CREATED", "order.created", false, List.of(CREATED))));
        String json = GraphJsonWriter.write(analyse());
        assertTrue(json.startsWith("{\"meta\":{\"root\":\"" + rootPath + "\""));
        assertTrue(json.contains("[\"" + CREATE.id() + "\",\"event:order.created\",\"emits\",\"" + SVC + "\",12,\"\"]"));
        assertTrue(json.contains("\"aka\":[{\"name\":\"Events.CREATED\",\"to\":null,\"file\":\"" + EVT + "\",\"line\":3,\"missing\":false}]"));
        assertNotNull(json);
    }
}
