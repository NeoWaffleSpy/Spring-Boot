package com.eventmapper.core.model;

import java.util.ArrayList;
import java.util.List;

/**
 * A graph node. Fields match the node objects of the page's JSON, so the existing page
 * renders it unchanged.
 */
public final class Node {

    /**
     * A constant naming an event: {@code String CREATED = "order.created"} ({@code to} null), or an
     * alias {@code String NEW = Events.CREATED} ({@code to} = "Events.CREATED").
     */
    public record Aka(String name, String to, String file, int line, boolean missing) {
    }

    public final String id;
    /** endpoint, event, handler, lambda, method or class (a method becomes a handler once it handles an event) */
    public String kind;
    public String label;
    /** qualified class the node belongs to, "" for events */
    public String cls = "";
    /** file relative to the root, or null */
    public String file;
    /** 1-based line, or 0 when unknown */
    public int line;
    public final List<String> roles = new ArrayList<>();
    /** endpoint path, or null */
    public String path;
    /** endpoint verb (GET, POST, ANY...), or null */
    public String verb;
    /** the String constants that hold the event's name (aliases included) */
    public final List<Aka> aka = new ArrayList<>();
    /** event name, or null */
    public String value;
    /** true when the code could not be resolved (drawn in red) */
    public boolean unres;

    public Node(String id, String kind, String label) {
        this.id = id;
        this.kind = kind;
        this.label = label;
    }

    public Node at(String file, int line) {
        this.file = file;
        this.line = line;
        return this;
    }

    public void addRole(String role) {
        if (!roles.contains(role)) {
            roles.add(role);
        }
    }
}
