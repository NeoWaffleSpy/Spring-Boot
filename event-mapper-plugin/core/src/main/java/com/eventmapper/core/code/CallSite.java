package com.eventmapper.core.code;

import java.util.List;

/**
 * A method call found in the project sources, e.g. {@code bus.emit(Events.CREATED, order)}.
 *
 * @param methodName   name of the called method ({@code emit})
 * @param receiverType qualified type of the receiver ({@code com.shop.EventBus}), or {@code null}
 *                     when there is no receiver or its type is unknown
 * @param arguments    the call's arguments, in order
 * @param enclosing    the method the call is written in, or {@code null} (field initialiser...)
 * @param lambda       start of the innermost lambda (inside {@code enclosing}) the call is written in,
 *                     or {@code null}; the same location as the lambda's {@link Argument} when that
 *                     lambda is passed to a call, which is how lambda handlers get their events
 * @param location     where the call is
 */
public record CallSite(String methodName, String receiverType, List<Argument> arguments,
                       MethodRef enclosing, SourceLocation lambda, SourceLocation location) {

    public CallSite {
        arguments = List.copyOf(arguments);
    }

    public Argument argument(int i) {
        return i < arguments.size() ? arguments.get(i) : null;
    }
}
