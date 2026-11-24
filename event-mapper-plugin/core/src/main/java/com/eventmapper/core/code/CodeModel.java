package com.eventmapper.core.code;

import java.util.List;
import java.util.Set;

/**
 * What the analysis needs to know about the code. Each IDE implements it on top of its own
 * indexes (IntelliJ: PSI; Eclipse: JDT), so the rules in core never touch an IDE class.
 *
 * <p>Implementations are called from a single thread, inside whatever read lock the IDE needs.
 * Queries with a default implementation are optional: without them the matching rules find nothing.
 */
public interface CodeModel {

    /** Absolute path of the project root, with '/' separators. */
    String rootPath();

    /** Every call in the project sources to a method with one of these names, whatever the receiver. */
    List<CallSite> findCalls(Set<String> methodNames);

    /** Every method in the project sources carrying an annotation with one of these simple names. */
    default List<AnnotatedMethod> findAnnotatedMethods(Set<String> annotationNames) {
        return List.of();
    }

    /**
     * Every call in the project sources to this method (any overload), with its enclosing method
     * and lambda; the arguments may be left empty.
     */
    default List<CallSite> callersOf(MethodRef method) {
        return List.of();
    }

    /** Lets a long analysis stop early when the user cancels it. Default: never cancelled. */
    default void checkCanceled() {
    }
}
