package com.eventmapper.core.model;

/**
 * A link between two nodes, written as {@code [src, dst, kind, file, line, as]} in the JSON.
 *
 * @param kind emits, handled_by, calls or http
 * @param as   how the event is written at that place in the code (e.g. {@code Events.CREATED}), or ""
 */
public record Edge(String src, String dst, String kind, String file, int line, String as) {
}
