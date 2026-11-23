package com.eventmapper.core;

import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Edge;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class EventMapperTest {

    private static final String SVC = "shop/src/main/java/com/shop/OrderService.java";
    private static final MethodRef CREATE = new MethodRef("com.shop.OrderService", "OrderService", "create", loc(SVC, 10));
    private static final MethodRef INIT = new MethodRef("com.shop.OrderService", "OrderService", "init", loc(SVC, 20));
    private static final MethodRef ON_CREATED = new MethodRef("com.shop.Mailer", "Mailer", "onCreated", loc("shop/src/main/java/com/shop/Mailer.java", 5));

    /** A code model answering from fixed call lists, standing in for an IDE. */
    private record FakeModel(String rootPath, List<CallSite> calls) implements CodeModel {
        @Override
        public List<CallSite> findCalls(Set<String> methodNames) {
            return calls.stream().filter(c -> methodNames.contains(c.methodName())).toList();
        }
    }

    private static SourceLocation loc(String f, int l) {
        return new SourceLocation(f, l);
    }

    @Test
    void connectsEmitsListenersAndLambdas(@TempDir Path root) throws IOException {
        Files.createDirectories(root.resolve("shop/src/main/java/com/shop"));
        Files.writeString(root.resolve("pom.xml"), "<project/>");
        Files.writeString(root.resolve("shop/pom.xml"), "<project/>");
        Files.writeString(root.resolve(SVC), "class OrderService {}");
        String rootPath = root.toString().replace('\\', '/');

        List<CallSite> calls = List.of(
                // bus.emit(Events.CREATED, order) in OrderService.create()
                new CallSite("emit", "com.shop.EventBus",
                        List.of(Argument.constant("Events.CREATED", "order.created", false), Argument.other("order")),
                        CREATE, null, loc(SVC, 12)),
                // bus.subscribe("order.created", mailer::onCreated) in init()
                new CallSite("subscribe", "com.shop.EventBus",
                        List.of(Argument.constant("\"order.created\"", "order.created", true),
                                Argument.methodReference("mailer::onCreated", ON_CREATED)),
                        INIT, null, loc(SVC, 21)),
                // bus.subscribe("order.paid", e -> bus.emit("order.shipped")) in init()
                new CallSite("subscribe", "com.shop.EventBus",
                        List.of(Argument.constant("\"order.paid\"", "order.paid", true),
                                Argument.lambda("e -> bus.emit(\"order.shipped\")", loc(SVC, 22))),
                        INIT, null, loc(SVC, 22)),
                new CallSite("emit", "com.shop.EventBus",
                        List.of(Argument.constant("\"order.shipped\"", "order.shipped", true)),
                        INIT, loc(SVC, 22), loc(SVC, 22)),
                // bus.emit(name) with a name only known at run time
                new CallSite("emit", "com.shop.EventBus", List.of(Argument.other("name")), CREATE, null, loc(SVC, 14)));

        Graph g = new EventMapper(MapperConfig.defaults()).analyse(new FakeModel(rootPath, calls));

        Node created = g.get("event:order.created");
        assertNotNull(created);
        assertEquals("Events.CREATED", created.label);
        assertEquals(List.of("\"order.created\""), created.aka);
        assertEquals("handler", g.get(ON_CREATED.id()).kind);
        assertTrue(g.edges().contains(new Edge(CREATE.id(), "event:order.created", "emits", SVC, 12, "Events.CREATED")));
        assertTrue(g.edges().contains(new Edge("event:order.created", ON_CREATED.id(), "handled_by", SVC, 21, "\"order.created\"")));

        // the lambda handling order.paid is also what emits order.shipped
        String lambda = "lambda:" + SVC + ":22";
        assertTrue(g.edges().contains(new Edge("event:order.paid", lambda, "handled_by", SVC, 22, "\"order.paid\"")));
        assertTrue(g.edges().contains(new Edge(lambda, "event:order.shipped", "emits", SVC, 22, "\"order.shipped\"")));

        Node unknown = g.get("unres:e:" + SVC + ":14:0");
        assertTrue(unknown.unres);
        assertEquals(1, g.unresolved.size());

        assertEquals(1, g.files);
        assertEquals(List.of(new Graph.Component("", root.getFileName().toString()), new Graph.Component("shop", "shop")), g.components);

        String json = GraphJsonWriter.write(g);
        assertTrue(json.startsWith("{\"meta\":{\"root\":\"" + rootPath + "\""));
        assertTrue(json.contains("[\"" + CREATE.id() + "\",\"event:order.created\",\"emits\",\"" + SVC + "\",12,\"Events.CREATED\"]"));
        assertTrue(json.contains("\"aka\":[\"\\\"order.created\\\"\"]"));
    }
}
