package com.eventmapper.core.model;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** The result of an analysis: what the page's JSON holds. */
public final class Graph {

    /** A folder holding a pom.xml. {@code dir} is relative to the root, "" for the root itself. */
    public record Component(String dir, String name) {
    }

    /** A call the analysis recognised but could not resolve; listed in the page's Issues view. */
    public record Unresolved(String file, int line, String scope, String text) {
    }

    public final String root;
    public final String generated;
    public int files;
    /** the SPECIAL_DIRS setting, e.g. "target=orange test=green" */
    public String special = "";
    public final List<Component> components = new ArrayList<>();
    public final List<Unresolved> unresolved = new ArrayList<>();

    private final Map<String, Node> nodes = new LinkedHashMap<>();
    private final Set<Edge> edges = new LinkedHashSet<>();

    public Graph(String root, String generated) {
        this.root = root;
        this.generated = generated;
    }

    /** Adds the node, or returns the one already registered under that id. */
    public Node node(Node n) {
        return nodes.computeIfAbsent(n.id, id -> n);
    }

    public Node get(String id) {
        return nodes.get(id);
    }

    public void edge(Edge e) {
        edges.add(e);
    }

    public Collection<Node> nodes() {
        return nodes.values();
    }

    public Collection<Edge> edges() {
        return edges;
    }
}
