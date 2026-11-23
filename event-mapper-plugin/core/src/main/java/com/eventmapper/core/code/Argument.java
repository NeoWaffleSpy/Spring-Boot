package com.eventmapper.core.code;

/**
 * One argument of a {@link CallSite}, already interpreted by the IDE adapter.
 *
 * @param kind     what the argument is
 * @param text     its source text, e.g. {@code Events.CREATED} or {@code this::onCreated}
 * @param constant the compile-time value when {@code kind} is {@link Kind#CONSTANT}, else {@code null}
 *                 (resolved through constants, static imports and string concatenation)
 * @param literal  {@code true} when the constant is written as a literal in the call itself
 * @param target   the method a {@link Kind#METHOD_REFERENCE} points to, or {@code null} if unresolved
 * @param location where a {@link Kind#LAMBDA} starts, else {@code null}
 */
public record Argument(Kind kind, String text, String constant, boolean literal, MethodRef target,
                       SourceLocation location) {

    public enum Kind { CONSTANT, METHOD_REFERENCE, LAMBDA, OTHER }

    public static Argument constant(String text, String value, boolean literal) {
        return new Argument(Kind.CONSTANT, text, value, literal, null, null);
    }

    public static Argument methodReference(String text, MethodRef target) {
        return new Argument(Kind.METHOD_REFERENCE, text, null, false, target, null);
    }

    public static Argument lambda(String text, SourceLocation location) {
        return new Argument(Kind.LAMBDA, text, null, false, null, location);
    }

    public static Argument other(String text) {
        return new Argument(Kind.OTHER, text, null, false, null, null);
    }
}
