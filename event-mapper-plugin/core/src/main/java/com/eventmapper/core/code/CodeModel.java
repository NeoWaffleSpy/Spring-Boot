package com.eventmapper.core.code;

import java.util.List;
import java.util.Set;

/**
 * What the analysis needs to know about the code. Each IDE implements it on top of its own
 * indexes (IntelliJ: PSI; Eclipse: JDT), so the rules in core never touch an IDE class.
 *
 * <p>Implementations are called from a single thread, inside whatever read lock the IDE needs.
 * More queries (annotated methods, class hierarchy...) are added here as rules are ported.
 */
public interface CodeModel {

    /** Absolute path of the project root, with '/' separators. */
    String rootPath();

    /** Every call in the project sources to a method with one of these names, whatever the receiver. */
    List<CallSite> findCalls(Set<String> methodNames);

    /** Lets a long analysis stop early when the user cancels it. Default: never cancelled. */
    default void checkCanceled() {
    }
}
