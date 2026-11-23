package com.eventmapper.core;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * The analysis settings, with the same names and defaults as the CONFIG block of
 * {@code Event_mapper.sh}. Settings are added here as their rules are ported.
 *
 * @param emitMethods   method names that fire an event: {@code bus.emit("x")}
 * @param listenMethods method names that register a listener: {@code bus.subscribe("x", this::onX)}
 * @param excludeDirs   folder names skipped anywhere in the tree
 * @param specialDirs   folder name to colour; scanned even if excluded, and tagged in the page
 */
public record MapperConfig(Set<String> emitMethods, Set<String> listenMethods, Set<String> excludeDirs,
                           Map<String, String> specialDirs) {

    public static MapperConfig defaults() {
        Map<String, String> special = new LinkedHashMap<>();
        special.put("target", "orange");
        special.put("test", "green");
        return new MapperConfig(
                Set.of("emit", "publish", "fire", "dispatch", "trigger", "raise"),
                Set.of("on", "subscribe", "hook", "listen", "addListener", "addHandler", "register",
                        "registerListener", "registerHandler"),
                Set.of("test", "tests", "build", "target", "out", "generated", ".git", "node_modules"),
                special);
    }

    /** Whether the analysis skips a folder with this name. */
    public boolean skips(String dirName) {
        return excludeDirs.contains(dirName) && !specialDirs.containsKey(dirName);
    }
}
