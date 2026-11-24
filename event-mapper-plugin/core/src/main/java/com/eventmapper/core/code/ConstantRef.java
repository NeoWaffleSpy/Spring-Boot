package com.eventmapper.core.code;

/**
 * A String constant an argument goes through to get its value, e.g. {@code Events.CREATED}.
 *
 * @param name     as the page shows it: simple class name and field, {@code Events.CREATED}
 * @param location where the constant is declared, or {@code null} outside the project sources
 */
public record ConstantRef(String name, SourceLocation location) {
}
