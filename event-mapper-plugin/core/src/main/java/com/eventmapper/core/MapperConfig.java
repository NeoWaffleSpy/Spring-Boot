package com.eventmapper.core;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/**
 * The analysis settings, with the same names, meaning and defaults as the CONFIG block of
 * {@code Event_mapper.sh}.
 *
 * @param emitMethods         method names that fire an event: {@code bus.emit("x")}
 * @param listenMethods       method names that register a listener: {@code bus.subscribe("x", this::onX)}
 * @param listenAnnotations   annotations marking a listener method: {@code @OnEvent("x")}, {@code @Subscribe}
 * @param eventAnnotationKeys annotation attributes holding the event name: {@code @OnEvent(event = "x")}
 * @param endpointAnnotations annotations marking an endpoint, to their verb ("" = any verb)
 * @param routeMethods        method names registering an endpoint at run time: {@code router.addRoute(VERB, name, handler)}
 * @param clientMethods       method names of HTTP clients: {@code restTemplate.getForObject("/orders", ..)}
 * @param pathAnnotations     annotations whose first string is a URL path (on a class: a prefix)
 * @param callbackMethods     method names taken as the callback of an object listener: {@code subscribe("x", new Foo())}
 * @param excludeDirs         folder names skipped anywhere in the tree
 * @param specialDirs         folder name to colour; scanned even if excluded, and tagged in the page
 * @param followCalls         follow plain method calls so chains connect
 */
public record MapperConfig(Set<String> emitMethods, Set<String> listenMethods, Set<String> listenAnnotations,
                           Set<String> eventAnnotationKeys, Map<String, String> endpointAnnotations,
                           Set<String> routeMethods, Set<String> clientMethods, Set<String> pathAnnotations,
                           Set<String> callbackMethods, Set<String> excludeDirs, Map<String, String> specialDirs,
                           boolean followCalls) {

    public static MapperConfig defaults() {
        Map<String, String> endpoints = new LinkedHashMap<>();
        for (String e : words("GetMapping=GET PostMapping=POST PutMapping=PUT DeleteMapping=DELETE PatchMapping=PATCH "
                + "RequestMapping=ANY GET=GET POST=POST PUT=PUT DELETE=DELETE PATCH=PATCH")) {
            String[] kv = e.split("=", 2);
            endpoints.put(kv[0], "ANY".equals(kv[1]) ? "" : kv[1]);
        }
        Map<String, String> special = new LinkedHashMap<>();
        special.put("target", "orange");
        special.put("test", "green");
        return new MapperConfig(
                words("emit publish fire dispatch trigger raise"),
                words("on subscribe hook listen addListener addHandler register registerListener registerHandler"),
                words("OnEvent Hook Subscribe EventHandler EventListener Listen Listener"),
                words("value event events topic topics name"),
                endpoints,
                words("addRoute"),
                words("getForObject getForEntity postForObject postForEntity postForLocation put delete patchForObject exchange uri"),
                words("RequestMapping Path"),
                words("handle onEvent on accept apply call run execute process notify"),
                words("test tests build target out generated .git node_modules"),
                special,
                true);
    }

    private static Set<String> words(String s) {
        return new LinkedHashSet<>(Arrays.asList(s.trim().split("\\s+")));
    }

    /** Whether the analysis skips a folder with this name. */
    public boolean skips(String dirName) {
        return excludeDirs.contains(dirName) && !specialDirs.containsKey(dirName);
    }

    /** Whether a file (path relative to the root) is in a skipped folder. */
    public boolean skipsFile(String path) {
        if (path == null) {
            return false;
        }
        String[] parts = path.split("/");
        for (int i = 0; i < parts.length - 1; i++) {
            if (skips(parts[i])) {
                return true;
            }
        }
        return false;
    }
}
