package com.eventmapper.core.code;

/**
 * A method declaration, as resolved by the IDE.
 *
 * @param className  qualified name of the declaring class, e.g. {@code com.shop.OrderService}
 * @param simpleName short display name of the declaring class, e.g. {@code OrderService}
 * @param name       method name
 * @param location   where it is declared, or {@code null} for a method from a library
 */
public record MethodRef(String className, String simpleName, String name, SourceLocation location) {

    /** Node id, the same as the bash analyser uses: {@code com.shop.OrderService#create}. */
    public String id() {
        return className + "#" + name;
    }

    /** Display label: {@code OrderService.create()}. */
    public String label() {
        return simpleName + "." + name + "()";
    }
}
