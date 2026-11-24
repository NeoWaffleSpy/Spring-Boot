package com.eventmapper.core.code;

import java.util.List;

/**
 * One argument of a {@link CallSite} (or an annotation value), already interpreted by the IDE adapter.
 *
 * @param kind     what the argument is
 * @param text     its source text, e.g. {@code Events.CREATED} or {@code this::onCreated}
 * @param constant the compile-time value when {@code kind} is {@link Kind#CONSTANT}, else {@code null}
 *                 (resolved through constants, static imports and string concatenation)
 * @param literal  {@code true} when the constant is written as a literal in the call itself
 * @param target   the method a {@link Kind#METHOD_REFERENCE} points to, or {@code null} if unresolved
 * @param location where a {@link Kind#LAMBDA} starts, else {@code null}
 * @param refs     for a constant read from a field: the chain of String constants followed to reach the
 *                 value, the one written in the code first ({@code A = B; B = "x"} gives [A, B]); else empty
 * @param pattern  for a String built at run time ({@code "/orders/" + id}): its known parts with
 *                 {@code {}} in place of the unknown ones ({@code "/orders/{}"}); else {@code null}
 * @param type     qualified type of an object argument ({@code new Foo()}, {@code this}, a variable),
 *                 a class literal's type ({@code Foo.class}), or {@code null}
 * @param methods  methods declared in that type in the project sources (inherited ones included, an
 *                 anonymous class's own methods for {@code new Foo() {...}}); empty when unknown
 */
public record Argument(Kind kind, String text, String constant, boolean literal, MethodRef target,
                       SourceLocation location, List<ConstantRef> refs, String pattern, String type,
                       List<MethodRef> methods) {

    public enum Kind { CONSTANT, METHOD_REFERENCE, LAMBDA, OTHER }

    public Argument {
        refs = refs == null ? List.of() : List.copyOf(refs);
        methods = methods == null ? List.of() : List.copyOf(methods);
    }

    public static Argument constant(String text, String value, boolean literal) {
        return constant(text, value, literal, List.of());
    }

    public static Argument constant(String text, String value, boolean literal, List<ConstantRef> refs) {
        return new Argument(Kind.CONSTANT, text, value, literal, null, null, refs, null, null, null);
    }

    public static Argument methodReference(String text, MethodRef target) {
        return new Argument(Kind.METHOD_REFERENCE, text, null, false, target, null, null, null, null, null);
    }

    public static Argument lambda(String text, SourceLocation location) {
        return new Argument(Kind.LAMBDA, text, null, false, null, location, null, null, null, null);
    }

    public static Argument other(String text) {
        return other(text, null, null, List.of());
    }

    public static Argument other(String text, String pattern, String type, List<MethodRef> methods) {
        return new Argument(Kind.OTHER, text, null, false, null, null, null, pattern, type, methods);
    }

    /** The argument's String value as far as it is known: the constant, else the pattern, else null. */
    public String stringValue() {
        return constant != null ? constant : pattern;
    }
}
