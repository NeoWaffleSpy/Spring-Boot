package com.eventmapper.core.page;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;

/**
 * Builds the event map page around a graph JSON. The page is {@code event-map.html} next to this
 * class (it started as a copy of the page {@code Event_mapper.sh} writes, and is now edited here):
 * {@code {{TITLE}}} is replaced by the title, {@code {{DATA}}} by the JSON.
 */
public final class PageRenderer {

    private static final String TEMPLATE = load();

    private PageRenderer() {
    }

    /** The page as a browser shows it: source locations as plain text. */
    public static String render(String title, String json) {
        return fill(title, json);
    }

    /**
     * The page as an IDE view shows it: source locations clickable (the IDE must define
     * {@code evmapOpen(file, line)} in the page), and the view state of a previous page restored.
     *
     * @param state what the previous page's {@code evmapState()} returned, or {@code null}
     */
    public static String renderForIde(String title, String json, String state) {
        String restore = state == null || state.isBlank() ? "null" : state.replace("</", "<\\/");
        return fill(title, json + ";\nwindow.EVMAP_HOST=true;window.EVMAP_RESTORE=" + restore);
    }

    private static String fill(String title, String data) {
        String page = TEMPLATE.replace("{{TITLE}}", escape(title));
        int at = page.indexOf("{{DATA}}");
        return page.substring(0, at) + data + page.substring(at + "{{DATA}}".length());
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }

    private static String load() {
        try (InputStream in = PageRenderer.class.getResourceAsStream("event-map.html")) {
            if (in == null) {
                throw new IllegalStateException("event-map.html is missing from the core jar");
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
